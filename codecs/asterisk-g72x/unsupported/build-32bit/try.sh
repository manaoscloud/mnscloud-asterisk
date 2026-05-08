#!/bin/sh
exec docker run -ti --rm -v $(pwd)/../..:/opt/asterisk-g72x asterisk-32bit:22 /bin/sh -c \
    'cp -v /opt/asterisk-g72x/bin/codec_g72?-ast220-gcc4-glibc-pentium4-sse3.so /opt/asterisk/lib/asterisk/modules/ \
    && /opt/asterisk/sbin/asterisk -f & sleep 5 && /opt/asterisk/sbin/asterisk -x "core show translation"'
