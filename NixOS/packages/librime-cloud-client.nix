{
  stdenv,
  lua5_2,
}:

# Native C Lua module (loaded by Rime's bundled Lua 5.2 runtime) that queries
# the local rime-google-cloud user service over a Unix domain socket with a
# strict 90ms socket timeout so typing stays responsive even offline.
stdenv.mkDerivation {
  name = "librime-cloud-client";
  buildInputs = [ lua5_2 ];
  dontUnpack = true;
  buildPhase = ''
    cat << 'EOF' > client.c
    #include <lua.h>
    #include <lauxlib.h>
    #include <sys/socket.h>
    #include <sys/un.h>
    #include <sys/time.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <string.h>
    #include <stdio.h>

    static int l_query(lua_State *L) {
        size_t len = 0;
        const char *code = luaL_checklstring(L, 1, &len);
        if (len < 4 || len > 48) {
            lua_pushliteral(L, "");
            return 1;
        }
        const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
        if (!runtime_dir || !runtime_dir[0]) {
            lua_pushliteral(L, "");
            return 1;
        }
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            lua_pushliteral(L, "");
            return 1;
        }
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 90000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/rime-google-cloud.sock", runtime_dir);

        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(fd);
            lua_pushliteral(L, "");
            return 1;
        }
        char req[64];
        int req_len = snprintf(req, sizeof(req), "%s\n", code);
        if (send(fd, req, (size_t)req_len, MSG_NOSIGNAL) < 0) {
            close(fd);
            lua_pushliteral(L, "");
            return 1;
        }
        char buf[256];
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        close(fd);
        if (n <= 0) {
            lua_pushliteral(L, "");
            return 1;
        }
        buf[n] = '\0';
        char *nl = strchr(buf, '\n');
        if (nl) *nl = '\0';
        lua_pushstring(L, buf);
        return 1;
    }

    int luaopen_rime_cloud(lua_State *L) {
        lua_newtable(L);
        lua_pushcfunction(L, l_query);
        lua_setfield(L, -2, "query");
        return 1;
    }
    EOF
    $CC -O2 -fPIC -shared client.c -llua -o librime_cloud_client.so
  '';
  installPhase = ''
    mkdir -p $out/lib
    cp librime_cloud_client.so $out/lib/
  '';
}
