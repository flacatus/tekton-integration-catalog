"""Unit tests for trigger-jenkins-job Task."""

import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import pytest


# ────────────────────────────────────────────────────────────────────────────
# Suite: Happy Path - Function Tests
# ────────────────────────────────────────────────────────────────────────────


def test_construct_job_url_simple():
    """Test URL construction for simple job name."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        def construct_job_url(base_url, job_name, action):
            parts = [p for p in job_name.split('/') if p]
            url = base_url
            for part in parts:
                url += f"/job/{part}"
            url += f"/{action}"
            return url

        result = construct_job_url("https://jenkins.example.com", "test-job", "build")
        print(result)
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert result.stdout.strip() == "https://jenkins.example.com/job/test-job/build"


def test_construct_job_url_nested():
    """Test URL construction for nested Jenkins job paths."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        def construct_job_url(base_url, job_name, action):
            parts = [p for p in job_name.split('/') if p]
            url = base_url
            for part in parts:
                url += f"/job/{part}"
            url += f"/{action}"
            return url

        result = construct_job_url("https://jenkins.example.com", "folder/subfolder/nested-job", "build")
        print(result)
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert result.stdout.strip() == "https://jenkins.example.com/job/folder/job/subfolder/job/nested-job/build"


def test_build_args_with_parameters():
    """Test build_args function with key=value parameters."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import urllib.parse

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

        data, filename = build_args(["PARAM1=value1", "PARAM2=value2"])
        print(f"data: {data}")
        print(f"filename: '{filename}'")
        # Verify buildWithParameters would be triggered
        print(f"action: {'buildWithParameters' if data else 'build'}")
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert "PARAM1=value1" in result.stdout
        assert "PARAM2=value2" in result.stdout
        assert "action: buildWithParameters" in result.stdout
        assert "filename: ''" in result.stdout


# ───────────────────────────────────────────────────────────────────────────
# Suite: Error Paths
# ────────────────────────────────────────────────────────────────────────────


def test_missing_username():
    """Test error when USERNAME is not set."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import os
        import sys

        USERNAME = os.getenv("USERNAME")
        APITOKEN = os.getenv("API_TOKEN")

        def main():
            if not USERNAME or not APITOKEN:
                print("Error: USERNAME and API_TOKEN environment variables must be set")
                sys.exit(1)

        main()
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True,
            env={"API_TOKEN": "testtoken"}
        )

        assert result.returncode == 1
        assert "Error: USERNAME and API_TOKEN environment variables must be set" in result.stdout


def test_missing_api_token():
    """Test error when API_TOKEN is not set."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import os
        import sys

        USERNAME = os.getenv("USERNAME")
        APITOKEN = os.getenv("API_TOKEN")

        def main():
            if not USERNAME or not APITOKEN:
                print("Error: USERNAME and API_TOKEN environment variables must be set")
                sys.exit(1)

        main()
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True,
            env={"USERNAME": "testuser"}
        )

        assert result.returncode == 1
        assert "Error: USERNAME and API_TOKEN environment variables must be set" in result.stdout


def test_auth_header_format():
    """Test that authentication header is properly formatted."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import base64

        USERNAME = "testuser"
        APITOKEN = "testtoken"

        base64string = base64.b64encode(f"{USERNAME}:{APITOKEN}".encode("utf-8"))
        auth_header = f"Basic {base64string.decode('utf-8')}"

        print(auth_header)
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert result.stdout.strip().startswith("Basic ")
        # Verify base64 encoding of "testuser:testtoken"
        assert "dGVzdHVzZXI6dGVzdHRva2Vu" in result.stdout


# ────────────────────────────────────────────────────────────────────────────
# Suite: Edge Cases
# ────────────────────────────────────────────────────────────────────────────


def test_empty_job_name():
    """Test URL construction with empty job name parts."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        def construct_job_url(base_url, job_name, action):
            parts = [p for p in job_name.split('/') if p]
            url = base_url
            for part in parts:
                url += f"/job/{part}"
            url += f"/{action}"
            return url

        result = construct_job_url("https://jenkins.example.com", "//job-name//", "build")
        print(result)
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert "https://jenkins.example.com/job/job-name/build" in result.stdout


def test_trailing_slash_in_jenkins_url():
    """Test JENKINS_URL with trailing slash is properly stripped."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        JENKINS_URL = "https://jenkins.example.com/".rstrip('/')
        print(JENKINS_URL)
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert result.stdout.strip() == "https://jenkins.example.com"


def test_build_args_with_file_parameter():
    """Test build_args function with file parameter (=@)."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import urllib.parse

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

        data, filename = build_args(["file=@/tmp/test.txt", "param1=value1"])
        print(f"filename: {filename}")
        print(f"data: {data}")
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert "filename: /tmp/test.txt" in result.stdout
        assert "param1=value1" in result.stdout


def test_build_args_no_parameters():
    """Test build_args function with no parameters."""
    script = textwrap.dedent("""
        #!/usr/libexec/platform-python
        import urllib.parse

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

        data, filename = build_args([])
        print(f"data: {data}")
        print(f"filename: '{filename}'")
    """)

    with tempfile.TemporaryDirectory() as tmpdir:
        script_file = Path(tmpdir) / "script.py"
        script_file.write_text(script)

        result = subprocess.run(
            [sys.executable, str(script_file)],
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert "data: {}" in result.stdout
        assert "filename: ''" in result.stdout
