# Sample app: hello (console) - prints from the packaged environment.
import os
import sys

def main(argv):
    data_dir = os.environ.get("APP_DATA_DIR") or os.path.dirname(sys.executable)
    print(f"HELLO_FROM_PACKAGED_APP python: {sys.executable}")
    print(f"version: {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
    print(f"app_data_dir: {data_dir}")
    print(f"args: {argv}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))