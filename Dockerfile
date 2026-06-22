#FROM postgres:18.3

# RUN apt-get update && \
#     apt-get install -y postgresql-15-partman && \
#     rm -rf /var/lib/apt/lists/*


#RUN apk add --no-cache \
#    postgresql18-dev \
#    gcc \
#    make \
#    git
#
#RUN git clone https://github.com/pgpartman/pg_partman.git
#RUN cd pg_partman && make && make install


FROM postgres:18.3

RUN apt-get update && \
    apt-get install -y postgresql-18-partman && \
    rm -rf /var/lib/apt/lists/*