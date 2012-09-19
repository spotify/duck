PREFIX?=/usr/local

DUCK_PATH=${PREFIX}/share/duck

install:
	mkdir -p ${DUCK_PATH}
	install -m 0755 bin/duck ${PREFIX}/bin/duck
	cp -ra duckcfg ${DUCK_PATH}/duckcfg
	cp -ra files ${DUCK_PATH}/files
	cp -ra fixes ${DUCK_PATH}/fixes

uninstall:
	rm -rf ${DUCK_PATH}
	rm -f ${PREFIX}/bin/duck
