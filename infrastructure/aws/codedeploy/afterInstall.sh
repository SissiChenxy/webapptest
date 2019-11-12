#!/bin/bash

#sudo systemctl stop tomcat.service
#sudo rm -rf /opt/tomcat/webapps/docs  /opt/tomcat/webapps/examples /opt/tomcat/webapps/host-manager  /opt/tomcat/webapps/manager /opt/tomcat/webapps/ROOT
#sudo chown tomcat:tomcat /opt/tomcat/webapps/ROOT.war
ps aux | grep java | xargs kill -9

# cleanup log files
# sudo rm -rf /opt/tomcat/logs/catalina*
# sudo rm -rf /opt/tomcat/logs/*.log
# sudo rm -rf /opt/tomcat/logs/*.txt
rm -rf /home/centos/spring.log
rm -rf /home/centos/access_log.log

# start application
source /etc/profile
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/home/centos/cloudwatch-config.json -s
nohup java -jar /home/centos/gs-spring-boot-0.1.1.jar &
