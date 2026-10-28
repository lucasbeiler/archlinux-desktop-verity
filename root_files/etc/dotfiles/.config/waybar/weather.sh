#!/bin/bash
 
TEMP=$(curl --fail -s 'https://www.climatempo.com.br/previsao-do-tempo/agora/cidade/377/florianopolis-sc' | grep -P 'currentWeather:' | sed 's/currentWeather://g' | jq  -r 'select(.name == "Florianópolis") | "\(.temperature)°C"' 2>/dev/null)
echo $TEMP
