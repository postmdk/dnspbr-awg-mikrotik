#!/bin/bash

docker buildx build --no-cache --platform linux/arm64 -t postmdk/awg-dnspbr:arm64 --load .
#docker buildx build --no-cache --platform linux/amd64 -t postmdk/awg-dnspbr:amd64 --load .
