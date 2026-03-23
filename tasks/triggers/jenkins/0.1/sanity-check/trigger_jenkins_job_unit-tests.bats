#!/usr/bin/env bats

setup() {
  export WORKDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/jenkins-trigger-${BATS_TEST_NUMBER}"
  mkdir -p "$WORKDIR"
  export SCRIPT_FILE="$WORKDIR/script.py"
  export MOCK_SERVER_FILE="$WORKDIR/mock_server.py"
  export PORT_FILE="$WORKDIR/port"

  # Create a mock HTTP server to simulate Jenkins
  cat << 'EOF' > "$MOCK_SERVER_FILE"
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys

class MockJenkinsHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = b''
        if content_length > 0:
            body = self.rfile.read(content_length)
            
        # Validate that parameters are actually sent when hitting buildWithParameters
        if self.path.endswith('/buildWithParameters'):
            if b'PARAM1' not in body:
                self.send_response(400)
                self.end_headers()
                return

        # Validate Authorization header
        if self.headers.get('Authorization') != 'Basic dXNlcjp0b2tlbg==':
            self.send_response(401)
            self.end_headers()
            return
            
        if self.path in ['/job/my-job/build', '/job/my-job/buildWithParameters', '/job/folder/job/my-job/build', '/job/file-job/build', '/job/file-job/buildWithParameters']:
            self.send_response(201)
            self.end_headers()
        elif self.path == '/job/fail-job/build':
            self.send_response(500)
            self.end_headers()
        elif self.path == '/job/weird-job/build':
            self.send_response(202)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

server = HTTPServer(('127.0.0.1', 0), MockJenkinsHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF

  python3 "$MOCK_SERVER_FILE" "$PORT_FILE" &
  export SERVER_PID=$!

  # Wait for port file to be written
  for _ in {1..50}; do
    if [ -f "$PORT_FILE" ]; then
      break
    fi
    sleep 0.1
  done
  export MOCK_PORT=$(cat "$PORT_FILE")
  export JENKINS_URL="http://127.0.0.1:${MOCK_PORT}"

  cat << 'EOF' > "$SCRIPT_FILE"
#!/usr/libexec/platform-python
import base64
import http.cookiejar
import os
import sys
import urllib.request
import ssl

# Create unverified SSL context
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

JENKINS_URL = """$(params.JENKINS_HOST_URL)""".rstrip('/')
JOB_NAME = """$(params.JOB_NAME)"""
USERNAME = os.getenv("USERNAME")
APITOKEN = os.getenv("API_TOKEN")

def construct_job_url(base_url, job_name, action):
    parts = [p for p in job_name.split('/') if p]
    url = base_url
    for part in parts:
        url += f"/job/{part}"
    url += f"/{action}"
    return url

def build_args(args):
    data = {}
    filename = ""
    for params in args:
        if "=@" in params:
            filename += params.split("=")[1][1:]
        elif "=" in params:
            key_value = params.split("=")
            data[key_value[0]] = key_value[1]
    if data:
        data = urllib.parse.urlencode(data).encode("utf-8")
    return (data, filename)

def main():
    try:
        if not USERNAME or not APITOKEN:
            print("Error: USERNAME and API_TOKEN environment variables must be set")
            sys.exit(1)

        # Process job parameters
        data, filename = build_args(sys.argv[1:])
        action = "buildWithParameters" if data else "build"

        # Get the URL and set up request
        job_url = construct_job_url(JENKINS_URL, JOB_NAME, action)
        print(f"Triggering Jenkins job at: {job_url}")

        # Set up authentication
        jarhead = http.cookiejar.CookieJar()
        base64string = base64.b64encode(f"{USERNAME}:{APITOKEN}".encode("utf-8"))
        auth_header = f"Basic {base64string.decode('utf-8')}"

        # Create form data for POST request
        if data:
            # Use provided parameters
            form_data = data
        else:
            # Use empty parameters
            form_data = urllib.parse.urlencode({
                'json': '{"parameter": []}'
            }).encode('utf-8')

        # Create the request
        request = urllib.request.Request(
            job_url,
            data=form_data,
            method='POST'
        )

        # Add headers
        request.add_header("Authorization", auth_header)
        request.add_header("Content-Type", "application/x-www-form-urlencoded")

        if filename:
            request.add_header("Content-Type", "multipart/form-data")
            request.add_header("Content-Length", str(os.stat(filename).st_size))
            request = urllib.request.Request(
                job_url,
                data=open(filename, "rb"),
                method='POST'
            )

        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ssl_context),
            urllib.request.HTTPCookieProcessor(jarhead)
        )

        with opener.open(request) as handle:
            if handle.status in [200, 201]:
                print("Jenkins job triggered successfully")
            else:
                print(f"Unexpected response status: {handle.status}")

    except Exception as e:
        print(f"Error triggering Jenkins job: {str(e)}")
        raise

main()
EOF
  chmod +x "$SCRIPT_FILE"
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}

prepare_script() {
  local job_name="${1:-my-job}"
  sed -i'' -e "s|\\\$(params.JENKINS_HOST_URL)|${JENKINS_URL}|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\\\$(params.JOB_NAME)|${job_name}|g" "$SCRIPT_FILE"
}

# ── Suite: Happy Path ──

@test "Happy path: trigger build without parameters" {
  prepare_script "my-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/my-job/build"* ]]
  [[ "$output" == *"Jenkins job triggered successfully"* ]]
}

@test "Happy path: trigger build with parameters" {
  prepare_script "my-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE" "PARAM1=value1" "PARAM2=value2"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/my-job/buildWithParameters"* ]]
  [[ "$output" == *"Jenkins job triggered successfully"* ]]
}

@test "Happy path: trigger build with folder job name" {
  prepare_script "folder/my-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/folder/job/my-job/build"* ]]
  [[ "$output" == *"Jenkins job triggered successfully"* ]]
}

# ── Suite: Error Paths ──

@test "Error path: missing USERNAME" {
  prepare_script "my-job"
  export USERNAME=""
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: USERNAME and API_TOKEN environment variables must be set"* ]]
}

@test "Error path: missing API_TOKEN" {
  prepare_script "my-job"
  export USERNAME="user"
  export API_TOKEN=""
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: USERNAME and API_TOKEN environment variables must be set"* ]]
}

@test "Error path: unauthorized credentials" {
  prepare_script "my-job"
  export USERNAME="wrong"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error triggering Jenkins job: HTTP Error 401: Unauthorized"* ]]
}

@test "Error path: server returns 500" {
  prepare_script "fail-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error triggering Jenkins job: HTTP Error 500: Internal Server Error"* ]]
}

@test "Error path: job not found (404)" {
  prepare_script "nonexistent-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error triggering Jenkins job: HTTP Error 404: Not Found"* ]]
}

@test "Error path: missing file for upload" {
  prepare_script "file-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE" "FILE=@$WORKDIR/nonexistent.txt"
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"No such file or directory"* ]]
}

# ── Suite: Edge Cases ──

@test "Edge case: trigger build with file upload parameter" {
  prepare_script "file-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  echo "dummy content" > "$WORKDIR/dummy.txt"
  
  run python3 "$SCRIPT_FILE" "FILE=@$WORKDIR/dummy.txt"
  
  # The script currently has a bug and drops the Authorization header, so this test will fail
  # with 401 Unauthorized. We assert the actual behavior of the script.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/file-job/build"* ]]
  [[ "$output" == *"Error triggering Jenkins job: HTTP Error 401: Unauthorized"* ]]
}

@test "Edge case: trigger build with both normal and file parameters" {
  prepare_script "file-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  echo "dummy content" > "$WORKDIR/dummy.txt"
  
  run python3 "$SCRIPT_FILE" "PARAM1=value1" "FILE=@$WORKDIR/dummy.txt"
  
  # The script currently has a bug and drops the form_data, so this test will fail
  # with 400 Bad Request. We assert the actual behavior of the script.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/file-job/buildWithParameters"* ]]
  [[ "$output" == *"Error triggering Jenkins job: HTTP Error 400: Bad Request"* ]]
}

@test "Edge case: invalid parameter format is ignored" {
  prepare_script "my-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE" "INVALID_PARAM"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Triggering Jenkins job at: ${JENKINS_URL}/job/my-job/build"* ]]
  [[ "$output" == *"Jenkins job triggered successfully"* ]]
}

@test "Edge case: unexpected success response status (e.g., 202)" {
  prepare_script "weird-job"
  export USERNAME="user"
  export API_TOKEN="token"
  
  run python3 "$SCRIPT_FILE"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unexpected response status: 202"* ]]
}