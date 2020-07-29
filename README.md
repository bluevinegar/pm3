# PM3

# process flow

* bin/pm3.dart send request to socket io on server
* lib/pm_socket.dart received and run command
* lib/pm.dart 

# TODO

* memory limit monitoring and restart

# Known bugs

* TODO

# deploy startup

vi /etc/rc.local
```
cd /home/ubuntu/ && su ubuntu -c 'nohup pm3 start &'
su ubuntu -c 'sleep 3 && pm3 resurrect'
```