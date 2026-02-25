#include <stdexcept>
#include <limits.h>
#include "window.h"

#ifndef WINDOW_TITLE
#define WINDOW_TITLE "eGrabber sample"
#endif

Window::Window(size_t width, size_t height) 
    : window(0)
    , renderer(0)
    , texture(0) {
    if (width >= INT_MAX || height >= INT_MAX) {
        throw std::runtime_error("dimensions out of range\n");
    }
    int iwidth = static_cast<int>(width);
    int iheight = static_cast<int>(height);
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        throw std::runtime_error("SDL_Init failed\n");
    }
    window = SDL_CreateWindow(WINDOW_TITLE, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, iwidth, iheight, 0);
    if (!window) {
        cleanup();
        throw std::runtime_error("SDL_CreateWindow failed\n");
    }
    renderer = SDL_CreateRenderer(window, -1, 0);
    if (!renderer) {
        cleanup();
        throw std::runtime_error("SDL_CreateRenderer failed\n");
    }
    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING, iwidth, iheight);
    if (!texture) {
        cleanup();
        throw std::runtime_error("SDL_CreateTexture failed\n");
    }
}

Window::~Window() {
    cleanup();
}

void Window::updateImage(void *data, size_t size) {
    void *pixels;
    int pitch;
    SDL_LockTexture(texture, NULL, &pixels, &pitch);
    memcpy(pixels, data, size);
    SDL_UnlockTexture(texture);
    SDL_RenderCopy(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
}

bool Window::isAlive() {
    SDL_Event event;
    if (!SDL_PollEvent(&event)) {
        return true;
    }
    if (event.type == SDL_QUIT || event.key.keysym.sym == SDLK_ESCAPE) {
        return false;
    }
    return true;
}

void Window::cleanup() {
    if (texture) {
        SDL_DestroyTexture(texture);
    }
    if (renderer) {
        SDL_DestroyRenderer(renderer);
    }
    if (window) {
        SDL_DestroyWindow(window);
    }
    SDL_Quit();
}
