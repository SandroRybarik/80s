LUA_LIB="/usr/local/lib/liblua.a"
LUA_INC="/usr/local/include/"

if [[ "${JIT}" == "true" ]]; then
    LUA_LIB="/usr/local/lib/libluajit-5.1.a"
    LUA_INC="/usr/local/include/luajit-2.0/"
fi

mkdir -p bin

DEFINES="-DWORKERS=${WORKERS:-4}"
LIBS="-lm -ldl -lpthread"

if [[ "$CRYPTO" == "true" ]]; then
    DEFINES="$DEFINES -DCRYPTOGRAPHIC_EXTENSIONS=true"
    LIBS="$LIBS -lcrypto"
fi

echo "Defines: $DEFINES"
echo "Libraries: $LIBS"
echo "Lua include directory: $LUA_INC"
echo "Lua library directory: $LUA_LIB"

gcc src/main.c src/lua.c "$LUA_LIB" \
    $DEFINES \
    "-I$LUA_INC" \
    $LIBS \
    -s -Ofast -march=native \
    -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Wno-stringop-overread \
    -o bin/80s