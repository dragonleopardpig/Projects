#include <string>
#include <SDL.h>

class Window {
public:
    Window(const Window &) = delete;
    Window &operator=(const Window &) = delete;
    Window(size_t width, size_t height);
    ~Window();

    void updateImage(void *data, size_t size);
    bool isAlive();

private:
    void cleanup();

private:
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Texture *texture;
};
