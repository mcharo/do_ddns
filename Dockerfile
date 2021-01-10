FROM ubuntu

RUN apt update \
    && apt install --no-install-recommends -y \
        jq \
        curl \
        ca-certificates

COPY /dodns.sh /

ENTRYPOINT ["/dodns.sh"]