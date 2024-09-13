#!/bin/bash

# 현재 실행 중인 Spring Boot 애플리케이션 포트 식별
CURRENT_PORT=$(sudo ss -tulnp | grep java | awk '{print $5}' | grep -o '[0-9]*$')
echo "Current port is: $CURRENT_PORT"

# 기본 포트 설정
PORT1=8081
PORT2=8082
NEW_PORT=0

# 현재 포트에 따라 새 포트 결정
if [ "$CURRENT_PORT" -eq "$PORT1" ]; then
    NEW_PORT=$PORT2
else
    NEW_PORT=$PORT1
fi

echo "Deploying new application on port: $NEW_PORT"

# 기존의 app-$NEW_PORT.jar 파일을 old_build 디렉토리로 이동
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
if [ -f /home/ubuntu/cicd/app-$NEW_PORT.jar ]; then
    mv /home/ubuntu/cicd/app-$NEW_PORT.jar /home/ubuntu/cicd/old_build/app-$NEW_PORT-$TIMESTAMP.jar
fi

# 새로 배포된 .jar 파일을 app-$NEW_PORT.jar로 이름 변경
NEW_JAR=$(ls /home/ubuntu/cicd/ZeroDownTimeDeployment-*.jar | head -n 1)
mv $NEW_JAR /home/ubuntu/cicd/app-$NEW_PORT.jar

# 새로 배포된 app-$NEW_PORT.jar 파일 실행
sudo chmod +x /home/ubuntu/cicd/app-$NEW_PORT.jar
sudo nohup java -jar -Dserver.port=$NEW_PORT /home/ubuntu/cicd/app-$NEW_PORT.jar > /home/ubuntu/console-$NEW_PORT.log 2>&1 &

sleep 20

# 헬스 체크 함수
health_check() {
    local port=$1
    local CHECK_URL="http://localhost:$port/actuator/health"
    local RETRY_COUNT=0
    local MAX_RETRY=10

    echo "Checking health on port $port..."

    until $(curl --output /dev/null --silent --head --fail $CHECK_URL); do
        sleep 5
        RETRY_COUNT=$((RETRY_COUNT+1))
        if [ $RETRY_COUNT -eq $MAX_RETRY ]; then
            echo "Health check failed on port $port"
            return 1
        fi
    done

    echo "Health check passed on port $port"
    return 0
}

# 헬스 체크
health_check $NEW_PORT
if [ $? -ne 0 ]; then
    sudo fuser -k $NEW_PORT/tcp
    sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$NEW_PORT.*;|server 127.0.0.1:$CURRENT_PORT;|" $NGINX_CONFIG
    sudo service nginx reload
    echo "Deployment failed. Rolling back."
    exit 1
fi

# Nginx 설정 파일에서 proxy_pass 동적으로 변경
NGINX_CONFIG="/etc/nginx/sites-available/default"

# Nginx 설정에서 canary 배포 설정 업데이트
echo "Configuring Nginx for canary deployment with 30% traffic to new version..."
sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$CURRENT_PORT;|server 127.0.0.1:$CURRENT_PORT weight=70; server 127.0.0.1:$NEW_PORT weight=30;|" $NGINX_CONFIG
sudo service nginx reload
# Nginx 재로드가 성공했는지 확인
if [ $? -ne 0 ]; then
		echo "Error: Failed to reload Nginx."
		exit 1
fi
sleep 10
# 추가 가중치 변경
for weight in 50 70; do
    echo "Updating Nginx for canary deployment with $weight% traffic to new version..."
    sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$CURRENT_PORT weight=[0-9]*; server 127.0.0.1:$NEW_PORT weight=[0-9]*;|server 127.0.0.1:$CURRENT_PORT weight=$((100-weight)); server 127.0.0.1:$NEW_PORT weight=$weight;|" $NGINX_CONFIG
    sudo service nginx reload
    # Nginx 재로드가 성공했는지 확인
		if [ $? -ne 0 ]; then
		    echo "Error: Failed to reload Nginx."
		    exit 1
		fi
		sleep 5
    health_check $NEW_PORT
    if [ $? -ne 0 ]; then
        sudo fuser -k $NEW_PORT/tcp
        sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$CURRENT_PORT weight=[0-9]*; server 127.0.0.1:$NEW_PORT weight=[0-9]*;|server 127.0.0.1:$CURRENT_PORT;|" $NGINX_CONFIG
        sudo service nginx reload
        echo "Deployment failed. Rolling back."
        exit 1
    fi
done


# 최종 Nginx 트래픽 신버전 포트로 100% 라우팅
echo "Finalizing Nginx configuration with 100% traffic to new version..."
sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$CURRENT_PORT weight=[0-9]*; server 127.0.0.1:$NEW_PORT weight=[0-9]*;|server 127.0.0.1:$NEW_PORT;|" $NGINX_CONFIG
sudo service nginx reload

# Nginx 재로드가 성공했는지 확인
if [ $? -ne 0 ]; then
    echo "Error: Failed to reload Nginx."
    exit 1
fi
sleep 5
health_check $NEW_PORT
if [ $? -ne 0 ]; then
    sudo fuser -k $NEW_PORT/tcp
    sudo sed -i "/upstream backend {/,/}/ s|server 127.0.0.1:$CURRENT_PORT weight=[0-9]*; server 127.0.0.1:$NEW_PORT weight=[0-9]*;|server 127.0.0.1:$CURRENT_PORT;|" $NGINX_CONFIG
    sudo service nginx reload
    echo "Deployment failed. Rolling back."
    exit 1
fi

# 구버전 JAR 파일을 old_build 폴더로 이동하고, 구버전 프로세스 종료
if [ "$CURRENT_PORT" -ne "$NEW_PORT" ]; then
    TIMESTAMP=$(date +"%Y%m%d%H%M%S")

    # 구버전 프로세스 종료
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

    # 구버전 JAR 파일을 old_build 폴더로 이동
    sudo mv /home/ubuntu/cicd/app-${CURRENT_PORT}.jar /home/ubuntu/cicd/old_build/app-${CURRENT_PORT}-${TIMESTAMP}.jar
    echo "Old version moved to old_build: app-${CURRENT_PORT}-${TIMESTAMP}.jar"
fi

echo "Canary deployment complete. New version is now serving 100% of traffic."
