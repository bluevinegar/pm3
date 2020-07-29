OSNAME=$(shell uname -s)

build:
ifeq ($(OSNAME),Linux)
	dart2native bin/pm3.dart
else
	docker exec pm3 dart2native /app/bin/pm3.dart
	docker cp pm3:/app/bin/pm3.exe ./bin/pm3.exe
endif
	rm -f bin/pm3 | true
	mv bin/pm3.exe bin/pm3

