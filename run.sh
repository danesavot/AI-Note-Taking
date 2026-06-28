#!/bin/bash
export GGML_METAL_ENABLED=0
exec swift run MeetingAssistantApp "$@"
