#ifndef WINDOWSSET_H_GUARD
#define WINDOWSSET_H_GUARD
#include <set>
#include <map>
#include "../common/window.h"

/** helper class to allow creation and management of multiple windows.
 *  There should be only one WindowsSet instance in your program.
 */
class WindowsSet {
    typedef Uint32 window_id_t;
    typedef int part_id_t;
    private:
        bool closingAllWindows = false;
        std::set<window_id_t> closedWindows;
        std::map<part_id_t, Window *> windows;
        static WindowsSet *instance;
        bool _shouldClose(window_id_t which);
    public:
        WindowsSet();
        ~WindowsSet();

        static bool shouldClose(window_id_t which);
        void add(part_id_t partno, Window *win) {
            windows[partno] = win;
        }
        Window *get(part_id_t partno);
        bool empty() const {
            return windows.empty();
        }
};


#endif
