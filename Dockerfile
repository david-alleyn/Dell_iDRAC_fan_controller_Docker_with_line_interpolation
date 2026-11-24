FROM ubuntu:latest

LABEL org.opencontainers.image.authors="tigerblue77"

RUN apt-get update

RUN apt-get install ipmitool -y

ADD functions.sh /app/functions.sh
ADD Dell_iDRAC_fan_controller.sh /app/Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /app/functions.sh /app/Dell_iDRAC_fan_controller.sh

WORKDIR /app

# you should override these default values when running. See README.md
ENV IDRAC_HOST 192.168.2.103
# ENV IDRAC_HOST local
#ENV IDRAC_USERNAME root
#ENV IDRAC_PASSWORD calvin
ENV FAN_SPEED 12
ENV CPU_TEMPERATURE_THRESHOLD 79
ENV CHECK_INTERVAL 30
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE true
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT false

ENV CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION 38
ENV HIGH_FAN_SPEED 60

CMD ["./Dell_iDRAC_fan_controller.sh"]
