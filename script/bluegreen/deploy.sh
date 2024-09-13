#!/bin/bash

# 현재 실행 중인 Spring Boot 애플리케이션 포트 식별
CURRENT_PORT=$(sudo ss -tulnp | grep java | awk '{print $5}' | grep -o '[0-9]*$')
echo "Current port is: $CURRENT_PORT"

# 기본 포트 설정
PORT1=8081
PORT2=8082
NEW_PORT=0

# 현재 포트에 따라 새 포트 결정
if [ -z "$CURRENT_PORT" ]; then
    # 실행 중인 포트가 없으면 기본 포트 사용
    NEW_PORT=$PORT1
elif [ "$CURRENT_PORT" -eq "$PORT1" ]; then
    NEW_PORT=$PORT2
else
    NEW_PORT=$PORT1
fi

echo "Deploying new application on port: $NEW_PORT"

# 기존의 app.jar 파일을 old_build 디렉토리로 이동
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
if [ -f /home/ubuntu/cicd/app-$CURRENT_PORT.jar ]; then
    mv /home/ubuntu/cicd/app-$CURRENT_PORT.jar /home/ubuntu/cicd/old_build/app-$CURRENT_PORT-$TIMESTAMP.jar
fi

# 새로 배포된 .jar 파일을 app-그린 포트.jar로 이름 변경
NEW_JAR=$(ls /home/ubuntu/cicd/ZeroDownTimeDeployment-*.jar | head -n 1)
mv $NEW_JAR /home/ubuntu/cicd/app-$NEW_PORT.jar

# 새로 배포된 app-그린 포트.jar 파일 실행
sudo chmod +x /home/ubuntu/cicd/app-$NEW_PORT.jar
sudo nohup java -jar -Dserver.port=$NEW_PORT /home/ubuntu/cicd/app-$NEW_PORT.jar > /home/ubuntu/console.log 2>&1 &

sleep 10
# 새 애플리케이션이 정상적으로 실행되었는지 확인
CHECK_URL=http://localhost:$NEW_PORT/actuator/health
RETRY_COUNT=0
MAX_RETRY=10

until $(curl --output /dev/null --silent --head --fail $CHECK_URL); do
    sleep 5
    if [ ${RETRY_COUNT} -eq ${MAX_RETRY} ]; then
        echo "New application failed to start. Deployment aborted."
        
        # 헬스 체크 실패 시 $NEW_PORT에서 실행 중인 프로세스를 강제 종료
        NEW_PID=$(lsof -t -i:$NEW_PORT)
        if [ -n "$NEW_PID" ]; then
            echo "Terminating process on port $NEW_PORT with PID $NEW_PID"
            sudo kill -9 $NEW_PID
        fi
        
        # 새로 배포된 JAR 파일을 old_build 디렉토리로 이동
        if [ -f /home/ubuntu/cicd/app-$NEW_PORT.jar ]; then
            mv /home/ubuntu/cicd/app-$NEW_PORT.jar /home/ubuntu/cicd/old_build/app-$NEW_PORT-$TIMESTAMP.jar
            echo "New version moved to old_build: app-$NEW_PORT-$TIMESTAMP.jar"
        fi

        # 이전 버전의 JAR 파일 복원
        if [ -f /home/ubuntu/cicd/old_build/app-$CURRENT_PORT-$TIMESTAMP.jar ]; then
            mv /home/ubuntu/cicd/old_build/app-$CURRENT_PORT-$TIMESTAMP.jar /home/ubuntu/cicd/app-$CURRENT_PORT.jar
            echo "Rolled back to the previous version $CURRENT_PORT Jar"
        else
            echo "Cannot Rolled back to the previous version $CURRENT_PORT Jar."
        fi

        exit 1
    fi
    RETRY_COUNT=$((RETRY_COUNT+1))
done

# Nginx 설정 파일에서 proxy_pass 동적으로 변경
NGINX_CONFIG="/etc/nginx/sites-available/default"
NEW_PROXY_PASS="proxy_pass http://127.0.0.1:$NEW_PORT;"

# listen 80번 포트의 location / 블록 내에서 proxy_pass 줄만 변경
sudo sed -i '/location \/ {/!b;n;s|proxy_pass http://127.0.0.1:.*;|'"$NEW_PROXY_PASS"'|' $NGINX_CONFIG

# sed 명령어가 성공했는지 확인
if [ $? -ne 0 ]; then
    echo "Error: Failed to update Nginx config."
    exit 1
fi

# Nginx 설정 재로드
sudo service nginx reload

# Nginx 재로드가 성공했는지 확인
if [ $? -ne 0 ]; then
    echo "Error: Failed to reload Nginx."
    exit 1
fi

# 이전 애플리케이션 종료
OLD_PID=$(lsof -t -i:$CURRENT_PORT)
if [ -n "$OLD_PID" ]; then
  sudo kill -15 $OLD_PID
  sleep 7
  # 프로세스가 여전히 종료되지 않았는지 확인하고, 강제 종료 시도
  if sudo kill -0 $OLD_PID 2>/dev/null; then
    echo "Process $OLD_PID did not terminate, killing with -9"
    sudo kill -9 $OLD_PID
  fi
fi

echo "Deployment complete. Nginx is routing traffic to port $NEW_PORT."
