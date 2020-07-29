# PM3

# Installing PM3

```
wget -qO- https://github.com/bluevinegar/pm3/raw/master/bin/pm3
sudo mv pm3 /usr/bin/

```

# start pm3 process in background

You can start the main process in background as the user that you wish to save configuration to $HOME/.pm3/

```
nohup pm3 start &
```
Your app is now daemonized, monitored and kept alive forever.


# Managing Applications

Once applications are started, you can manage them easily.

To list all running applications

```
pm3 list
```

Managing apps is straightforward:

```
pm3 stop <app_name>|'all'|json_conf
pm3 restart <app_name>|'all'
pm3 delete <app_name>|'all'
```

Example

```
pm3 start app.json
```

To save running process for persisted restart:
```
pm3 save
```

To restore last saved process:

```
pm3 delete all # this will remove all running processes (cannot undo)
pm3 resurrect# loads saved processers
```

To view logs:

```
pm3 log <app_name>
```

# process flow

* bin/pm3.dart send request to socket io on server
* lib/pm_socket.dart received and run command
* lib/pm.dart 

# TODO

* memory limit monitoring and restart

# Known bugs

* TODO

# deploy to system startup

```
# vi /etc/rc.local
cd /home/ubuntu/ && su ubuntu -c 'nohup pm3 start &'
su ubuntu -c 'sleep 3 && pm3 resurrect'
```