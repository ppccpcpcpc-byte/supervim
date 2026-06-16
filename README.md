# SuperVim
---
SuperVim은 C + Python + Shared Library(.so) 구조로 제작된 경량 Vim 스타일 텍스트 에디터입니다.

특징

- Vim 스타일 키바인딩
- Gap Buffer 기반 편집 엔진
- 비동기 저장(Async Save)
- Shared Library 기반 모듈화
- ARM64 지원
- Linux / Termux 지원
- Undo / Redo
- Visual Mode
- Yank / Delete / Paste
- 파일 생성 및 편집

---

프로젝트 구조

myedi/
├── build/
│   └── libsupervim.so
├── core/
│   ├── supervim.h
│   ├── gapbuffer.c
│   ├── cursor.c
│   ├── mode.c
│   ├── ops.c
│   ├── fileio.c
│   ├── async.c
│   └── extra.c
├── py/
│   ├── __init__.py
│   ├── ffi.py
│   ├── input.py
│   ├── render.py
│   └── editor.py
├── build.sh
├── run.py
└── README.md

---

구성 요소

libsupervim.so

에디터 핵심 엔진

기능:

- Gap Buffer
- Cursor 이동
- Undo/Redo
- Visual Mode
- Yank/Delete/Paste
- File I/O
- Async Save

---

C 모듈

gapbuffer.c

문서 저장 구조

기능:

- 문자 삽입
- 문자 삭제
- Gap 이동
- 텍스트 직렬화

cursor.c

커서 이동

기능:

- h
- j
- k
- l
- Home
- End

mode.c

에디터 모드

모드:

- NORMAL
- INSERT
- VISUAL

ops.c

문서 조작

기능:

- yy
- dd
- p
- u
- Ctrl+r

fileio.c

파일 저장 및 로드

기능:

- 파일 열기
- 파일 저장
- 새 파일 생성

async.c

비동기 저장

기능:

- Worker Thread
- Background Save
- Save Queue

---

Python 모듈

ffi.py

ctypes 기반 FFI

역할:

- libsupervim.so 로드
- C 함수 연결

input.py

키 입력 처리

지원:

- ESC
- 화살표 키
- Home
- End

render.py

화면 렌더링

기능:

- 상태 표시줄
- 커서 표시
- 번호 표시

editor.py

메인 이벤트 루프

역할:

- Vim 명령 처리
- 모드 전환
- 저장 명령 처리

---

빌드

```
chmod +x conf.sh
./conf.sh
```

---

실행

새 파일 생성:

`python run.py test.txt`

기존 파일 열기:

`python run.py README.md`

---

기본 키

NORMAL MODE

키| 기능
i| INSERT
a| APPEND
o| 아래 줄 생성
O| 위 줄 생성
h j k l| 이동
yy| 줄 복사
dd| 줄 삭제
p| 붙여넣기
u| Undo
Ctrl+r| Redo
gg| 맨 위
G| 맨 아래
V| Visual

---

INSERT MODE

키| 기능
ESC| NORMAL
Enter| 줄바꿈
Backspace| 삭제

---

COMMAND MODE

명령| 기능
:w| 저장
:q| 종료
:q!| 강제 종료
:wq| 저장 후 종료
:e file| 파일 열기
:w file| 다른 이름 저장

---

목표

- Nano보다 강력
- Vim과 유사한 사용성
- ARM64 최적화
- 모듈형 구조
- 경량 에디터

---

Version: 1.0

Project Name: SuperVim
