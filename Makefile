CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c99
LIBS = -lX11 -lXinerama
TARGET = retropie-osd
SOURCE = src/retropie-osd.c
INSTALL_DIR = /usr/local/bin
SERVICE_DIR = /etc/systemd/system
CONTROL_SCRIPT = retropie-osd-control

.PHONY: all clean install uninstall service-install service-uninstall

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCE) $(LIBS)

install: $(TARGET)
	sudo cp $(TARGET) $(INSTALL_DIR)/
	sudo chmod +x $(INSTALL_DIR)/$(TARGET)
	sudo cp scripts/$(CONTROL_SCRIPT) $(INSTALL_DIR)/
	sudo chmod +x $(INSTALL_DIR)/$(CONTROL_SCRIPT)

service-install: install
	sudo cp systemd/retropie-osd.service $(SERVICE_DIR)/
	sudo systemctl daemon-reload
	sudo systemctl enable retropie-osd

service-uninstall:
	sudo systemctl stop retropie-osd || true
	sudo systemctl disable retropie-osd || true
	sudo rm -f $(SERVICE_DIR)/retropie-osd.service
	sudo systemctl daemon-reload

uninstall: service-uninstall
	sudo rm -f $(INSTALL_DIR)/$(TARGET)
	sudo rm -f $(INSTALL_DIR)/$(CONTROL_SCRIPT)

clean:
	rm -f $(TARGET)

test: $(TARGET)
	@echo "Testing OSD compilation..."
	@echo "Run './$(TARGET)' to test (requires X11 and EmulationStation)"

debug: CFLAGS += -g -DDEBUG
debug: $(TARGET)

release: CFLAGS += -DNDEBUG
release: $(TARGET)
