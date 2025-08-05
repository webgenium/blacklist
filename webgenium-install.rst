/system script 
add name="webgenium-blacklist-dl" source={/tool fetch url="https://github.com/webgenium/blacklist/raw/main/webgenium-blacklist.rsc" mode=https}
add name="webgenium-blacklist-run" source {/system script run webgenium-blacklist.rsc}
/system scheduler 
add interval=7d name="dl-mt-blacklist" start-date=Jan/01/2000 start-time=00:05:00 on-event=webgenium-blacklist-dl
add interval=7d name="ins-mt-blacklist" start-date=Jan/01/2000 start-time=00:10:00 on-event=webgenium-blacklist-run
