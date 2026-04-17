🤖 ROS2 Jazzy 강의 - Day 2/30
━━━━━━━━━━━━━━━━━━

📚 **주제**: 노드(Node)와 통신 모델

📖 **이론**

### 노드(Node)란?

ROS2의 기본 구성 단위로, 특정 기능을 수행하는 독립적인 실행 프로그램입니다. 각 노드는:
- 단일 프로세스에서 실행됩니다
- 특정 작업을 수행합니다 (예: 센서 데이터 수집, 모터 제어)
- 다른 노드와 통신하여 시스템 전체의 기능을 구현합니다

### 노드의 특징

1. **모듈성**: 시스템을 작은 기능 단위로 분할
2. **분산 처리**: 여러 노드가 병렬로 작동
3. **재사용성**: 다른 시스템에서 재사용 가능
4. **독립성**: 각 노드는 독립적으로 실행/중지 가능

### ROS2 통신 모델

ROS2는 4가지 주요 통신 방식을 제공합니다:

1. **토픽(Topic)**: 단방향 통신 (Publisher ↔ Subscriber)
2. **서비스(Service)**: 요청-응답 방식 (Server ↔ Client)
3. **액션(Action)**: 장기 실행 작업 (Server ↔ Client)
4. **파라미터(Parameter)**: 노드 간 설정 공유

### 노드 관리 명령어

```bash
# 현재 실행 중인 노드 목록 확인
ros2 node list

# 노드 정보 확인
ros2 node info /노드이름

# 토픽 목록 확인
ros2 topic list

# 서비스 목록 확인
ros2 service list
```

💻 **코드 예시**

### Python 노드 기본 구조 (talker/listener 예제)

**1. Talker (Publisher) 노드**
```python
#!/usr/bin/env python3
import rclpy
from rclpy.node import Node
from std_msgs.msg import String

class MinimalPublisher(Node):
    def __init__(self):
        super().__init__('minimal_publisher')
        self.publisher_ = self.create_publisher(String, 'topic', 10)
        timer_period = 0.5  # 0.5초마다 발행
        self.timer = self.create_timer(timer_period, self.timer_callback)
        self.count = 0

    def timer_callback(self):
        msg = String()
        msg.data = f'Hello ROS2: {self.count}'
        self.publisher_.publish(msg)
        self.get_logger().info(f'Publishing: {msg.data}')
        self.count += 1

def main(args=None):
    rclpy.init(args=args)
    minimal_publisher = MinimalPublisher()
    rclpy.spin(minimal_publisher)
    minimal_publisher.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    main()
```

**2. Listener (Subscriber) 노드**
```python
#!/usr/bin/env python3
import rclpy
from rclpy.node import Node
from std_msgs.msg import String

class MinimalSubscriber(Node):
    def __init__(self):
        super().__init__('minimal_subscriber')
        self.subscription = self.create_subscription(
            String,
            'topic',
            self.listener_callback,
            10)
        self.subscription  # prevent unused variable warning

    def listener_callback(self, msg):
        self.get_logger().info(f'I heard: {msg.data}')

def main(args=None):
    rclpy.init(args=args)
    minimal_subscriber = MinimalSubscriber()
    rclpy.spin(minimal_subscriber)
    minimal_subscriber.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    main()
```

### 실행 방법

**1. 패키지 생성**
```bash
cd ~/ros2_ws/src
ros2 pkg create --build-type ament_python py_topic_demo
```

**2. 소스 파일 저장**
- `talker.py`와 `listener.py`를 `py_topic_demo/py_topic_demo/`에 저장

**3. 실행 터미널 1 (Publisher)**
```bash
cd ~/ros2_ws
colcon build --packages-select py_topic_demo
source install/setup.bash
ros2 run py_topic_demo talker
```

**4. 실행 터미널 2 (Subscriber)**
```bash
cd ~/ros2_ws
source install/setup.bash
ros2 run py_topic_demo listener
```

📝 **오늘의 과제**

1. **기초 과제**:
   - 위 코드를 따라서 실행해보세요
   - `ros2 node list` 명령어로 실행 중인 노드 확인
   - `ros2 topic list` 명령어로 토픽 확인
   - `ros2 topic echo /topic`으로 메시지 내용 확인

2. **연습 문제**:
   - 발행 주기를 1초로 변경해보세요
   - 메시지 내용을 다른 형식으로 바꿔보세요 (예: f'Current time: {datetime.now()}')
   - 발행 횟수를 100번으로 제한하는 코드 추가

3. **심화 과제**:
   - 서비스(Service) 통신 방식으로 노드 간 통신 구현
   - 요청 메시지: `std_srvs/srv/Empty`
   - 응답 메시지: "Service request received"

🎯 **다음 시간**: Day 3 - 토픽(Topic) - 단방향 통신 심화