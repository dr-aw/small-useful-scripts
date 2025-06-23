#!/bin/bash

# Check API-KEY:
if [ -z "${GEMINI_API_KEY}" ]; then
  echo "Ошибка: Переменная окружения GEMINI_API_KEY не установлена."
  echo "Выполните: export GEMINI_API_KEY='Ваш_ключ'"
  exit 1
fi

# Check input
if [ -z "$1" ]; then
  echo "Correct input: ./gemini.sh \"Your input\""
  exit 1
fi

# RAW check
if [ "$1" == "--raw" ]; then
  RAW=1
  shift # Delete flag
else
  RAW=0
fi

# Collect everything, in the beginning with something like system-prompt
PROMPT="Пиши по делу, в спартанском стиле. Не используй markdown: *, **, \`, заголовки, списки и прочее. Выделяй важное цветом ANSI (если уместно), а не оформлением. Ответь на запрос: $*"

#echo $PROMPT
#echo "___________________"
echo ""


# Main CURL request
RESPONSE=$(curl -s  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "{\"contents\":[{\"parts\":[{\"text\":\"${PROMPT}\"}]}]}"
 # -d '{"contents":[{"parts":[{"text":'${PROMPT}'}]}]}'
)

# Responce
if [ "$RAW" -eq 1 ]; then
  echo "$RESPONSE"
else
 TEXT=$( echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text')
 printf "%b\n" "$TEXT" # Now colors working
fi
