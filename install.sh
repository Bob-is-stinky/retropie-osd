#!/bin/bash

# RetroPie OSD Installation Script
# For Raspberry Pi OS Lite with Pi Sugar 2 Plus

set -e

echo "=========================================="
echo "RetroPie OSD Installation Script"
echo "=========================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root"
   exit 1
fi

# Check if we're on Raspberry Pi OS
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    print_warning "This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Install required packages
print_status "Installing required packages..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    libx11-dev \
    libxinerama-dev \
    i2c-tools \
    git

# Enable I2C if not already enabled
print_status "Checking I2C configuration..."
if ! grep -q "^dtparam=i2c_arm=on" /boot/config.txt; then
    print_status "Enabling I2C..."
    echo "dtparam=i2c_arm=on" | sudo tee -a /boot/config.txt
    if ! grep -q "^i2c-dev" /etc/modules; then
        echo "i2c-dev" | sudo tee -a /etc/modules
    fi
    print_warning "I2C has been enabled. You may need to reboot for changes to take effect."
fi

# Add user to i2c group
print_status "Adding user to i2c group..."
sudo usermod -a -G i2c $USER

# Create installation directory
INSTALL_DIR="/opt/retropie-osd"
print_status "Creating installation directory: $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"

# Download or copy source files
print_status "Installing RetroPie OSD..."

# Create the main C source file
sudo tee "$INSTALL_DIR/retropie-osd.c" > /dev/null << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <time.h>
#include <signal.h>
#include <sys/wait.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xinerama.h>

#define PISUGAR_I2C_ADDR 0x57
#define PISUGAR_I2C_BUS "/dev/i2c-1"
#define UPDATE_INTERVAL 10  // seconds
#define FONT_SIZE 16
#define BAR_HEIGHT 30
#define TEXT_MARGIN 10

typedef struct {
    Display *display;
    Window window;
    GC gc;
    XFontStruct *font;
    int screen_width;
    int screen_height;
    int running;
} OSDContext;

// Global context for signal handling
OSDContext *g_osd = NULL;

// Signal handler for graceful shutdown
void signal_handler(int sig) {
    if (g_osd) {
        g_osd->running = 0;
    }
}

// Check if EmulationStation is running
int is_emulationstation_running() {
    FILE *cmd = popen("pgrep emulationstation", "r");
    if (!cmd) return 0;
    
    char buffer[32];
    int found = (fgets(buffer, sizeof(buffer), cmd) != NULL);
    pclose(cmd);
    return found;
}

// Read battery percentage from Pi Sugar 2 Plus
int read_battery_percentage() {
    int file = open(PISUGAR_I2C_BUS, O_RDWR);
    if (file < 0) {
        // Fallback: try to read from sysfs if available
        FILE *bat_file = fopen("/sys/class/power_supply/pisugar-battery/capacity", "r");
        if (bat_file) {
            int percentage;
            if (fscanf(bat_file, "%d", &percentage) == 1) {
                fclose(bat_file);
                return percentage;
            }
            fclose(bat_file);
        }
        return -1;
    }
    
    if (ioctl(file, I2C_SLAVE, PISUGAR_I2C_ADDR) < 0) {
        close(file);
        return -1;
    }
    
    // Pi Sugar 2 Plus battery level command
    char cmd = 0x22;  // Battery level register
    if (write(file, &cmd, 1) != 1) {
        close(file);
        return -1;
    }
    
    usleep(10000);  // Small delay for I2C
    
    char data[2];
    if (read(file, data, 2) != 2) {
        close(file);
        return -1;
    }
    
    close(file);
    
    // Convert to percentage (adjust based on Pi Sugar 2 Plus protocol)
    int percentage = (data[0] << 8) | data[1];
    if (percentage > 100) percentage = 100;
    if (percentage < 0) percentage = 0;
    
    return percentage;
}

// Get current time string
void get_time_string(char *buffer, size_t size) {
    time_t now = time(NULL);
    struct tm *local = localtime(&now);
    strftime(buffer, size, "%H:%M", local);
}

// Initialize OSD display
int init_osd(OSDContext *osd) {
    osd->display = XOpenDisplay(NULL);
    if (!osd->display) {
        fprintf(stderr, "Cannot open display\n");
        return 0;
    }
    
    int screen = DefaultScreen(osd->display);
    osd->screen_width = DisplayWidth(osd->display, screen);
    osd->screen_height = DisplayHeight(osd->display, screen);
    
    // Create overlay window
    XSetWindowAttributes attrs;
    attrs.override_redirect = True;
    attrs.background_pixel = BlackPixel(osd->display, screen);
    attrs.border_pixel = BlackPixel(osd->display, screen);
    attrs.event_mask = ExposureMask;
    
    osd->window = XCreateWindow(
        osd->display,
        RootWindow(osd->display, screen),
        0, 0,  // Position at top-left
        osd->screen_width, BAR_HEIGHT,
        0,     // Border width
        CopyFromParent,
        InputOutput,
        CopyFromParent,
        CWOverrideRedirect | CWBackPixel | CWBorderPixel | CWEventMask,
        &attrs
    );
    
    // Load font
    osd->font = XLoadQueryFont(osd->display, "-*-fixed-medium-r-*-*-14-*-*-*-*-*-*-*");
    if (!osd->font) {
        osd->font = XLoadQueryFont(osd->display, "fixed");
    }
    
    // Create graphics context
    osd->gc = XCreateGC(osd->display, osd->window, 0, NULL);
    XSetForeground(osd->display, osd->gc, WhitePixel(osd->display, screen));
    XSetBackground(osd->display, osd->gc, BlackPixel(osd->display, screen));
    
    if (osd->font) {
        XSetFont(osd->display, osd->gc, osd->font->fid);
    }
    
    // Set window to be always on top
    Atom wm_state = XInternAtom(osd->display, "_NET_WM_STATE", False);
    Atom wm_state_above = XInternAtom(osd->display, "_NET_WM_STATE_ABOVE", False);
    
    XChangeProperty(osd->display, osd->window, wm_state, XA_ATOM, 32,
                    PropModeReplace, (unsigned char*)&wm_state_above, 1);
    
    XMapWindow(osd->display, osd->window);
    XFlush(osd->display);
    
    osd->running = 1;
    return 1;
}

// Update OSD display
void update_osd(OSDContext *osd) {
    char time_str[32];
    char battery_str[32];
    char battery_display[64];
    
    get_time_string(time_str, sizeof(time_str));
    
    int battery_level = read_battery_percentage();
    if (battery_level >= 0) {
        snprintf(battery_display, sizeof(battery_display), "%d%%", battery_level);
    } else {
        strcpy(battery_display, "AC");
    }
    
    // Clear window
    XClearWindow(osd->display, osd->window);
    
    // Draw semi-transparent background
    XSetForeground(osd->display, osd->gc, 0x000000);
    XFillRectangle(osd->display, osd->window, osd->gc, 0, 0, osd->screen_width, BAR_HEIGHT);
    
    // Set text color
    XSetForeground(osd->display, osd->gc, 0xFFFFFF);
    
    // Draw time on left side
    int text_y = (BAR_HEIGHT + (osd->font ? osd->font->ascent : 12)) / 2;
    XDrawString(osd->display, osd->window, osd->gc, TEXT_MARGIN, text_y,
                time_str, strlen(time_str));
    
    // Draw battery on right side
    int battery_width = XTextWidth(osd->font, battery_display, strlen(battery_display));
    int battery_x = osd->screen_width - battery_width - TEXT_MARGIN;
    XDrawString(osd->display, osd->window, osd->gc, battery_x, text_y,
                battery_display, strlen(battery_display));
    
    // Draw battery icon (simple rectangle)
    if (battery_level >= 0) {
        int icon_x = battery_x - 30;
        int icon_y = (BAR_HEIGHT - 12) / 2;
        
        // Battery outline
        XDrawRectangle(osd->display, osd->window, osd->gc, icon_x, icon_y, 20, 12);
        XDrawRectangle(osd->display, osd->window, osd->gc, icon_x + 20, icon_y + 3, 3, 6);
        
        // Battery fill based on level
        if (battery_level > 20) {
            XSetForeground(osd->display, osd->gc, 0x00FF00);  // Green
        } else if (battery_level > 10) {
            XSetForeground(osd->display, osd->gc, 0xFFFF00);  // Yellow
        } else {
            XSetForeground(osd->display, osd->gc, 0xFF0000);  // Red
        }
        
        int fill_width = (battery_level * 18) / 100;
        XFillRectangle(osd->display, osd->window, osd->gc, icon_x + 1, icon_y + 1,
                       fill_width, 10);
        
        XSetForeground(osd->display, osd->gc, 0xFFFFFF);  // Reset to white
    }
    
    XFlush(osd->display);
}

// Cleanup OSD resources
void cleanup_osd(OSDContext *osd) {
    if (osd->display) {
        if (osd->gc) XFreeGC(osd->display, osd->gc);
        if (osd->font) XFreeFont(osd->display, osd->font);
        if (osd->window) XDestroyWindow(osd->display, osd->window);
        XCloseDisplay(osd->display);
    }
}

int main() {
    OSDContext osd = {0};
    g_osd = &osd;
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    printf("RetroPie OSD starting...\n");
    
    // Main loop
    while (1) {
        // Check if EmulationStation is running
        if (!is_emulationstation_running()) {
            if (osd.display) {
                cleanup_osd(&osd);
                memset(&osd, 0, sizeof(osd));
                g_osd = &osd;
                printf("EmulationStation not running, hiding OSD\n");
            }
            sleep(5);
            continue;
        }
        
        // Initialize OSD if not already done
        if (!osd.display) {
            if (init_osd(&osd)) {
                printf("OSD initialized\n");
            } else {
                printf("Failed to initialize OSD, retrying...\n");
                sleep(5);
                continue;
            }
        }
        
        // Update display
        update_osd(&osd);
        
        // Handle X11 events
        while (XPending(osd.display)) {
            XEvent event;
            XNextEvent(osd.display, &event);
            if (event.type == Expose) {
                update_osd(&osd);
            }
        }
        
        // Check if we should exit
        if (!osd.running) {
            break;
        }
        
        sleep(UPDATE_INTERVAL);
    }
    
    cleanup_osd(&osd);
    printf("RetroPie OSD shutting down\n");
    return 0;
}
EOF

# Create Makefile
sudo tee "$INSTALL_DIR/Makefile" > /dev/null << 'EOF'
CC = gcc
CFLAGS = -Wall -Wextra -O2
LIBS = -lX11 -lXinerama
TARGET = retropie-osd
SOURCE = retropie-osd.c

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCE) $(LIBS)

install: $(TARGET)
	sudo cp $(TARGET) /usr/local/bin/
	sudo chmod +x /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: install clean
EOF

# Compile the program
print_status "Compiling RetroPie OSD..."
cd "$INSTALL_DIR"
sudo make

# Install the binary
print_status "Installing binary..."
sudo make install

# Create systemd service
print_status "Creating systemd service..."
sudo tee /etc/systemd/system/retropie-osd.service > /dev/null << EOF
[Unit]
Description=RetroPie OSD
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
User=$USER
Group=$USER
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/retropie-osd
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

# Create control script
print_status "Creating control script..."
sudo tee /usr/local/bin/retropie-osd-control > /dev/null << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "Starting RetroPie OSD..."
        sudo systemctl start retropie-osd
        ;;
    stop)
        echo "Stopping RetroPie OSD..."
        sudo systemctl stop retropie-osd
        ;;
    restart)
        echo "Restarting RetroPie OSD..."
        sudo systemctl restart retropie-osd
        ;;
    status)
        sudo systemctl status retropie-osd
        ;;
    enable)
        echo "Enabling RetroPie OSD to start on boot..."
        sudo systemctl enable retropie-osd
        ;;
    disable)
        echo "Disabling RetroPie OSD from starting on boot..."
        sudo systemctl disable retropie-osd
        ;;
    logs)
        sudo journalctl -u retropie-osd -f
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|enable|disable|logs}"
        exit 1
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/retropie-osd-control

# Enable and start the service
print_status "Enabling and starting RetroPie OSD service..."
sudo systemctl daemon-reload
sudo systemctl enable retropie-osd
sudo systemctl start retropie-osd

print_status "Installation complete!"
echo ""
echo "=========================================="
echo "RetroPie OSD has been installed successfully!"
echo "=========================================="
echo ""
echo "Control commands:"
echo "  retropie-osd-control start    - Start the OSD"
echo "  retropie-osd-control stop     - Stop the OSD"
echo "  retropie-osd-control restart  - Restart the OSD"
echo "  retropie-osd-control status   - Check status"
echo "  retropie-osd-control logs     - View logs"
echo ""
echo "The OSD will automatically:"
echo "- Start when your system boots"
echo "- Show only when EmulationStation is running"
echo "- Display time on the left and battery on the right"
echo ""
echo "Note: You may need to reboot if I2C was just enabled."
echo ""
print_status "Checking service status..."
sudo systemctl status retropie-osd --no-pager
