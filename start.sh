#!/bin/bash
PROJECT="${1:-.}"

tmux new-session -d -s pair-dev -x 220 -y 50
tmux split-window -h -t pair-dev:0

tmux send-keys -t pair-dev:0.0 "cd $PROJECT && claude" Enter
tmux send-keys -t pair-dev:0.1 "cd $PROJECT && claude" Enter

tmux attach -t pair-dev
