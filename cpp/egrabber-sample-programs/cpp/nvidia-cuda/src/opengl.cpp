#ifdef _WIN32
    #include <GL/glew.h>
    #include <GL/freeglut.h>
    #include <GL/gl.h>
    #include <GL/wglext.h>
#else
    #include <GL/glxew.h>
    #include <GL/freeglut.h>
    #include <GL/glxext.h>
#endif

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <iostream>

#include "egrabber-cuda.h"

#define REFRESH_DELAY 0

namespace {

GLuint quad;
GLuint tex;

int mouse_old_x;
int mouse_old_y;
int mouse_buttons = 0;
float rotate_x = 0.0;
float rotate_y = 0.0;

const float pArray[] = {
    -1.0f,  1.0f, 0.0f, 0.0f,
     1.0f,  1.0f, 1.0f, 0.0f,
     1.0f, -1.0f, 1.0f, 1.0f,
    -1.0f, -1.0f, 0.0f, 1.0f,
};

void keyboard(unsigned char key, int /*x*/, int /*y*/) {
    switch (key) {
    case 27: glutLeaveMainLoop(); break;
    default: break;
    }
}

void closing() {
    cleanupCudaResources();
}

void mouse(int button, int state, int x, int y) {
    if (state == GLUT_DOWN) {
        mouse_buttons |= 1 << button;
    }
    else if (state == GLUT_UP) {
        mouse_buttons = 0;
    }

    mouse_old_x = x;
    mouse_old_y = y;
}

void motion(int x, int y) {
    float dx, dy;
    dx = (float)(x - mouse_old_x);
    dy = (float)(y - mouse_old_y);

    if (mouse_buttons & 1) {
        rotate_x += dy * 0.2f;
        rotate_y += dx * 0.2f;
    }

    mouse_old_x = x;
    mouse_old_y = y;
}

void refresh(int /*value*/) {
    if (glutGetWindow()) {
        glutPostRedisplay();
        glutTimerFunc(REFRESH_DELAY, refresh, 0);
    }
}

void display() {
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glRotatef(rotate_x, 1.0, 0.0, 0.0);
    glRotatef(rotate_y, 0.0, 1.0, 0.0);

    glBindTexture(GL_TEXTURE_2D, tex);
        if (!updateTexture()) {
            glutLeaveMainLoop();
            return;
        }
        glBindBuffer(GL_ARRAY_BUFFER, quad);
            glDrawArrays(GL_QUADS, 0, 4);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);

    glutSwapBuffers();
}

void disableVSync() {
    const char *cStrExtensions = reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
    if (!cStrExtensions) {
        throw std::runtime_error("glGetString GL_EXTENSIONS failed");
    }

#ifdef _WIN32
    #define EXT_swap_control "WGL_EXT_swap_control"
#else
    #define EXT_swap_control "GLX_EXT_swap_control"
#endif
    std::string extensions(cStrExtensions);
    std::size_t canDisableVSync = extensions.find(EXT_swap_control) != std::string::npos;
    if (!canDisableVSync) {
        throw std::runtime_error(EXT_swap_control " extension is not supported");
    }

#ifdef _WIN32
    PFNWGLSWAPINTERVALEXTPROC wglSwapIntervalEXT = (PFNWGLSWAPINTERVALEXTPROC)wglGetProcAddress("wglSwapIntervalEXT");
    if (!wglSwapIntervalEXT) {
        throw std::runtime_error("wglGetProcAddress for OpenGL extension function wglSwapIntervalEXT failed");
    }

    wglSwapIntervalEXT(0);
#else
    PFNGLXSWAPINTERVALEXTPROC glXSwapIntervalEXT = (PFNGLXSWAPINTERVALEXTPROC)glXGetProcAddress((const GLubyte *)"glXSwapIntervalEXT");
    if (!glXSwapIntervalEXT) {
        throw std::runtime_error("glGetProcAddress for OpenGL extension function glXSwapIntervalEXT failed");
    }

    Display *dpy = glXGetCurrentDisplay();
    GLXDrawable drawable = glXGetCurrentDrawable();
    glXSwapIntervalEXT(dpy, drawable, 0);
#endif
}

} // namespace

void initOpenGL(int *argc, char **argv) {
    glutInit(argc, argv);
    glutInitDisplayMode(GLUT_RGBA | GLUT_DOUBLE);
    glutInitWindowSize(800, 600);
    glutCreateWindow("EGrabber/CUDA/OpenGL sample program");
    std::cout << "GL_VENDOR:  \t" << reinterpret_cast<const char *>(glGetString(GL_VENDOR)) << std::endl;
    std::cout << "GL_RENDERER:\t" << reinterpret_cast<const char *>(glGetString(GL_RENDERER)) << std::endl;
    std::cout << "GL_VERSION: \t" << reinterpret_cast<const char *>(glGetString(GL_VERSION)) << std::endl;
    if (options[SHOWEXTENSIONS]) {
        std::cout << "GL_EXTENSIONS:\t" << reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS)) << std::endl;
    }
    glutKeyboardFunc(keyboard);
    glutCloseFunc(closing);
    glutMouseFunc(mouse);
    glutMotionFunc(motion);
    glutDisplayFunc(display);
    glutTimerFunc(REFRESH_DELAY, refresh, 0);
    glutSetOption(GLUT_ACTION_ON_WINDOW_CLOSE, GLUT_ACTION_CONTINUE_EXECUTION);
    if (options[DISABLEVSYNC]) {
        disableVSync();
    }
}

GLuint setupGLObjects(size_t width, size_t height) {
    glMatrixMode(GL_PROJECTION);
    glOrtho(-2, 2, -2, 2, -2, 2);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_TEXTURE_2D);
    glShadeModel(GL_SMOOTH);
    glPolygonMode(GL_FRONT, GL_FILL);

    glGenBuffers(1, &quad);
    glBindBuffer(GL_ARRAY_BUFFER, quad);
        glBufferData(GL_ARRAY_BUFFER, 16 * sizeof(float), pArray, GL_STATIC_DRAW);
        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glVertexPointer(2, GL_FLOAT, 4 * sizeof(float), 0);
        glTexCoordPointer(2, GL_FLOAT, 4 * sizeof(float), (char *)0 + 2 * sizeof(float));
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, (GLsizei)width, (GLsizei)height, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);

    glClearColor(0.0, 0.0, 0.25, 1.0);
    return tex;
}
