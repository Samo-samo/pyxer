# Sample app: hello_gui (PySide6) - a tiny window to prove a GUI build.
import os
import sys

from PySide6.QtCore import QSize
from PySide6.QtWidgets import QApplication, QLabel, QVBoxLayout, QWidget

def main(argv):
    app = QApplication(argv)
    win = QWidget()
    win.setWindowTitle("pyxer hello_gui")
    win.setMinimumSize(QSize(280, 120))
    lay = QVBoxLayout(win)
    data_dir = os.environ.get("APP_DATA_DIR") or os.path.dirname(sys.executable)
    lay.addWidget(QLabel("pyxer packaged PySide6 app"))
    lay.addWidget(QLabel(f"data dir: {data_dir}"))
    win.show()
    return app.exec()

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))