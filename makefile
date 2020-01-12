shotwell:
	find ~/Photos  -type f -delete || true
	find ~/Pictures -type f -delete || true
	/bin/rm -rvf ~/Desktop/testdata/
	mkdir -p ~/Desktop/testdata/
	/usr/bin/time -v cp --update -fv $(shell ls /tmp/transfer/IMG_9*.CR2 | shuf | head -n 10 ) ~/Desktop/testdata/
	ninja -C build -v
