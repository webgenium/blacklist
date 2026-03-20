/ip firewall address-list
:foreach i in=[find list=webgenium-blacklist] do={ remove $i }

