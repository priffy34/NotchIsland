# Как залить новый релиз на GitHub

## Один раз: подготовка

1. Установи инструменты (Homebrew: https://brew.sh):

       xcode-select --install
       brew install gh

2. Войди в GitHub из терминала:

       gh auth login

   Выбери `GitHub.com` → `HTTPS` → `Login with a web browser` и подтверди код в браузере.

3. Создай репозиторий. Если папка проекта ещё не git-репозиторий (ты скачал её архивом, внутри нет `.git`):

       cd путь/к/NotchIsland-main
       git init -b main
       git add -A
       git commit -m "Initial commit"
       gh repo create NotchIsland --public --source=. --remote=origin --push

   Если репозиторий на GitHub уже есть, то вместо `gh repo create`:

       git remote add origin https://github.com/ТВОЙ_НИК/NotchIsland.git
       git push -u origin main

   (Если в папке уже есть `.git` и remote настроен — этот шаг пропусти.)

## Каждый новый релиз (самый простой способ)

В папке проекта выполни одну команду, указав номер версии:

    ./release.sh 1.1

Скрипт сам:
1. пропишет версию в `Info.plist`;
2. соберёт приложение (`./build.sh`);
3. упакует `NotchIsland-1.1.zip`;
4. закоммитит изменения и сделает `git push`;
5. создаст релиз `v1.1` на GitHub и приложит к нему zip.

Если скрипт «не запускается» (permission denied):

    chmod +x release.sh build.sh

Для следующих релизов просто увеличивай номер: `./release.sh 1.2`, `./release.sh 1.3`…
Один и тот же номер использовать нельзя — GitHub скажет, что тег уже существует.

## Вручную, без скрипта (через сайт)

1. `./build.sh` — получится `NotchIsland.app`.
2. Упакуй: `ditto -c -k --keepParent NotchIsland.app NotchIsland-1.1.zip`
3. Закоммить и отправь код: `git add -A && git commit -m "v1.1" && git push`
4. На странице репозитория: **Releases → Draft a new release**.
5. В поле Tag введи `v1.1` → **Create new tag**, заголовок — `NotchIsland 1.1`.
6. Перетащи `NotchIsland-1.1.zip` в область «Attach binaries».
7. Нажми **Publish release**.

## Частые проблемы

- `gh: command not found` — не установлен GitHub CLI (`brew install gh`).
- `HTTP 401` / `not logged in` — выполни `gh auth login` ещё раз.
- `fatal: no upstream branch` — один раз выполни `git push -u origin main`.
- `tag already exists` — возьми номер версии больше предыдущего.
- Пользователям: приложение не нотаризовано, при первом запуске — правый клик → Открыть,
  либо `xattr -cr /Applications/NotchIsland.app`.
