#include <stdexcept>
#include <iostream>
#include <limits.h>
#include "windowsSet.h"

#ifndef WINDOW_TITLE
#define WINDOW_TITLE "eGrabber sample"
#endif

WindowsSet *WindowsSet::instance = nullptr;

WindowsSet::WindowsSet() {
    if (instance) {
        throw std::runtime_error("Unexpected error: attempt to create multiple WindowsSet");
    }
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        throw std::runtime_error("SDL_Init failed\n");
    }
    instance = this;
}

WindowsSet::~WindowsSet() {
    for (auto it = windows.begin(); it != windows.end(); ++it) {
        delete it->second;
    }
    windows.clear();
    SDL_Quit();
    instance = nullptr;
}

bool WindowsSet::shouldClose(window_id_t which) {
    if (instance) {
        return instance->_shouldClose(which);
    } else {
        return true;
    }
}

bool WindowsSet::_shouldClose(window_id_t which) {
    SDL_Event event;
    if (closingAllWindows) {
        return true;
    }
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_WINDOWEVENT) {
            if (event.window.event == SDL_WINDOWEVENT_CLOSE) {
                closedWindows.insert(event.window.windowID);
            }
        }
        if (event.type == SDL_QUIT ||
            (event.type == SDL_KEYUP && event.key.keysym.sym == SDLK_ESCAPE)) {
            closingAllWindows = true;
            return true;
        }
    }
    if (closedWindows.find(which) != closedWindows.end()) {
        return true;
    }
    return false;
}

Window *WindowsSet::get(part_id_t part) {
    auto found = windows.find(part);
    if (found == windows.end()) {
        return nullptr;
    }
    if (!found->second->isAlive()) {
        std::cout << "Window for part " << part << " is no longer alive" << std::endl;
        delete windows[part];
        windows.erase(found);
        return nullptr;
    }
    return found->second;
}


Window::Window(size_t width, size_t height) 
    : window(0)
    , renderer(0)
    , texture(0)
{
    static int originX = SDL_WINDOWPOS_UNDEFINED;
    static int originY = SDL_WINDOWPOS_UNDEFINED;
    if (width >= INT_MAX || height >= INT_MAX) {
        throw std::runtime_error("dimensions out of range\n");
    }
    int iwidth = static_cast<int>(width);
    int iheight = static_cast<int>(height);

    window = SDL_CreateWindow(WINDOW_TITLE, originX, originY, iwidth, iheight, SDL_WINDOW_RESIZABLE);
    if (!window) {
        cleanup();
        throw std::runtime_error("SDL_CreateWindow failed\n");
    }
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) {
        cleanup();
        throw std::runtime_error("SDL_CreateRenderer failed\n");
    }
    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING, iwidth, iheight);
    if (!texture) {
        cleanup();
        throw std::runtime_error("SDL_CreateTexture failed\n");
    }
    SDL_GetWindowPosition(window, &originX, &originY);
    originX += 50; originY += 50;
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
    if (WindowsSet::shouldClose(SDL_GetWindowID(window))) {
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
}
