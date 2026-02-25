#include <iostream>
#include <EGenTL.h>                                            // 1

void listCards() {
    Euresys::EGenTL gentl;                                     // 2
    GenTL::TL_HANDLE tl = gentl.tlOpen();                      // 3
    uint32_t numCards = gentl.tlGetNumInterfaces(tl);          // 4
    for (uint32_t n = 0; n < numCards; ++n) {
        std::string id = gentl.tlGetInterfaceID(tl, n);        // 5
        std::cout << "[" << n << "] " << id << std::endl;
    }
}

int main() {
    try {                                                       // 6
        listCards();
    } catch (const std::exception &e) {                         // 6
        std::cout << "error: " << e.what() << std::endl;
    }
}
