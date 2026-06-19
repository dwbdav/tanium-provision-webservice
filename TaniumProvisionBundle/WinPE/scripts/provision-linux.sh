#!/bin/bash

echo "provision-linux.sh 10.9.71.0"

# Make sure we are in the correct folder
cd /_t
mkdir -p /opt/Tanium/TaniumClient/Logs
mkdir -p /opt/Tanium/TaniumClient/Tools

# Add tag(s)
tags=$(jq -r ".Tags" /_t/settings.json)
if [[ -n $tags ]]
then
  tagList=$(echo "$tags" | tr ",", "\n")
  echo "Writing tags:"
  echo "$tagList"
  echo "$tagList" >> /opt/Tanium/TaniumClient/Tools/CustomTags.txt
else
  echo "Writing default OSD tag"
  echo "OSD" >> /opt/Tanium/TaniumClient/Tools/CustomTags.txt
fi

# Install the Tanium client
/bin/bash /_t/provision-linux-client.sh

# Cleanup
cp /_t/logs/*.log /opt/Tanium/TaniumClient/Logs/
rm -R /_t
