gcc src/main.c src/lua.c -I/usr/local/include/ -llua -lm -s -march=native -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Ofast -o bin/server