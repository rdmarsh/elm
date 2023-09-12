#!/bin/bash
#outputs csv list of the alertExpr used for PercentUsed of the root
#volume for all devices in a group
set -euo pipefail
IFS=$'\n\t'

#change to real group id
gid="9999"
dsname="SNMP_Filesystem_Usage"
inname="/"
dpname="PercentUsed"

for device in $(elm -f csv DeviceList -s0 -F "hostGroupIds~${gid}" -f id,displayName) ; do
    echo -n "${device},"
    deviceId=${device%%,*}
    for hds in $(elm -f csv DeviceDatasourceList -s0 --deviceId ${deviceId} -F "dataSourceName:${dsname}" -f id,dataSourceDisplayName) ; do
        echo -n "${hds},"
        hdsId=${hds%%,*}
        for instance in $(elm -f csv DeviceDatasourceInstanceList -s0 --deviceId ${deviceId} --hdsId ${hdsId} -F "name:${dsname}-${inname}" -f id,displayName) ; do
            echo -n "${instance},"
            instanceId=${instance%%,*}
            elm DeviceDatasourceInstanceAlertSettingListOfDSI -s0 --deviceId ${deviceId} --hdsId ${hdsId} --instanceId ${instanceId} | \
                jq -r --arg jq_dpname ${dpname} '.DeviceDatasourceInstanceAlertSettingListOfDSI[] | select(.dataPointName==$ARGS.named.jq_dpname) | [.dataPointName, .alertExpr] | @csv' | \
                tr -d '"'
            sleep 1
        done
    done
done

