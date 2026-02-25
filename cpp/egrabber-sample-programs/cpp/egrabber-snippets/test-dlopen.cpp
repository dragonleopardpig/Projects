#include <dlfcn.h>
#include <iostream>

int main() {
    const char *libs[] = {
        "/opt/euresys/egrabber/lib/x86_64/libegrabber.so",
        "/opt/euresys/egrabber/lib/x86_64/coaxlink.cti",
        NULL
    };

    for (int i = 0; libs[i]; i++) {
        std::cout << "dlopen(" << libs[i] << ")..." << std::endl;
        void *h = dlopen(libs[i], RTLD_NOW);
        if (!h) {
            std::cout << "  FAILED: " << dlerror() << std::endl;
        } else {
            std::cout << "  OK" << std::endl;
            dlclose(h);
        }
    }
    return 0;
}
