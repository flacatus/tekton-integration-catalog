import os
import sys
import textwrap
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import pytest
import subprocess

class MockJenkinsHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            self.rfile.read(content_length)
            
        if 'exception' in self.path:
            # Simulate a network error by closing the connection abruptly
            self.connection.close()
            return
            
        if 'fail' in self.path:
            # Simulate a server error
            self.send_response(500)
            self.end_headers()
            return
            
        if 'unexpected' in self.path:
            # Simulate an unexpected but successful status code
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b"Accepted")
            return
            
        # Default success response
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"Created")

@pytest.fixture(scope="module")
def mock_jenkins_server():
    server = HTTPServer(('127.0.0.1', 0), MockJenkinsHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.daemon = True
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()

@pytest.fixture
def script_env(tmp_path, mock_jenkins_server):
    script_content = textwrap.dedent('''\
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
    ''')

    def create_script(job_name="test-job"):
        content = script_content.replace("$(params.JENKINS_HOST_URL)", mock_jenkins_server)
        content = content.replace("$(params.JOB_NAME)", job_name)
        script_file = tmp_path / f"script_{job_name.replace('/', '_')}.py"
        script_file.write_text(content)
        return script_file

    env = os.environ.copy()
    env["USERNAME"] = "mock-user"
    env["API_TOKEN"] = "mock-token"

    return create_script, env, tmp_path

def run_script(script_file, env, args=None):
    cmd = [sys.executable, str(script_file)] + (args or [])
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=30)
    return result.returncode, result.stdout, result.stderr

class TestHappyPath:
    def test_success_no_args(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("my-job")
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode == 0
        assert "Triggering Jenkins job at:" in stdout
        assert "/job/my-job/build" in stdout
        assert "Jenkins job triggered successfully" in stdout

    def test_success_with_data_args(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("folder/my-job")
        args = ["PARAM1=value1", "PARAM2=value2"]
        returncode, stdout, stderr = run_script(script_file, env, args)
        
        assert returncode == 0
        assert "/job/folder/job/my-job/buildWithParameters" in stdout
        assert "Jenkins job triggered successfully" in stdout

    def test_success_with_file_arg(self, script_env):
        create_script, env, tmp_path = script_env
        script_file = create_script("my-job")
        
        upload_file = tmp_path / "payload.txt"
        upload_file.write_text("dummy content")
        
        args = [f"FILE=@{upload_file}"]
        returncode, stdout, stderr = run_script(script_file, env, args)
        
        assert returncode == 0
        assert "Jenkins job triggered successfully" in stdout

class TestErrorPaths:
    def test_missing_username(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("my-job")
        del env["USERNAME"]
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode == 1
        assert "Error: USERNAME and API_TOKEN environment variables must be set" in stdout

    def test_missing_apitoken(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("my-job")
        del env["API_TOKEN"]
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode == 1
        assert "Error: USERNAME and API_TOKEN environment variables must be set" in stdout

    def test_unexpected_response_status(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("unexpected")
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode == 0
        assert "Unexpected response status: 202" in stdout

    def test_http_error_500(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("fail")
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode != 0
        assert "Error triggering Jenkins job: HTTP Error 500" in stdout

    def test_network_exception(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("exception")
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode != 0
        assert "Error triggering Jenkins job:" in stdout

class TestEdgeCases:
    def test_empty_job_name(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("")
        returncode, stdout, stderr = run_script(script_file, env)
        
        assert returncode == 0
        assert "/build" in stdout
        assert "Jenkins job triggered successfully" in stdout

    def test_malformed_args(self, script_env):
        create_script, env, _ = script_env
        script_file = create_script("my-job")
        args = ["INVALID_ARG"]
        returncode, stdout, stderr = run_script(script_file, env, args)
        
        assert returncode == 0
        assert "/job/my-job/build" in stdout
        assert "Jenkins job triggered successfully" in stdout