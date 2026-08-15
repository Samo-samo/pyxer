# Sample app: pygame - proves a non-PySide6 third-party dependency gets
# carried into the shared runtime by the dependency scanner.
import os
import sys

def main(argv):
    try:
        import pygame
    except ImportError:
        print("PYGAME_MISSING", file=sys.stderr)
        return 1
    pygame.init()
    print(f"PYGAME_OK pygame: {pygame.version.ver}")
    pygame.quit()
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))