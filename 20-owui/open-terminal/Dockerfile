# Open TerminalへPi coding agent、OfficeCLI、Open WebUI Agent Skillsを追加する派生image。
# build contextは20-owui。skillsはrepository直下の20-owui/skillsから取り込む。
# multi-user modeではagentがOpen WebUI userごとのOS userで起動するため、
# /home/user (mode 700) ではなく全userが実行できる/usr/localへ導入する。
FROM ghcr.io/open-webui/open-terminal:0.17.22

ARG PI_VERSION=1.6.0
ARG OFFICECLI_VERSION=1.0.163

USER root

# OfficeCLIのpostinstallはrelease binaryを取得するため、build時だけnetworkを必要とする。
RUN npm install --global --prefix /usr/local \
      "@earendil-works/pi-coding-agent@${PI_VERSION}" \
      "@officecli/officecli@${OFFICECLI_VERSION}" \
    && npm cache clean --force

# userごとのPi agent directoryへ配布する雛形を作る。skillはbuild時に固定する。
COPY open-terminal/pi/models.json /etc/inferlab/pi/agent/models.json
COPY open-terminal/pi/settings.json /etc/inferlab/pi/agent/settings.json
COPY open-terminal/pi/AGENTS.md /etc/inferlab/pi/agent/AGENTS.md
RUN mkdir -p /tmp/officecli-skel/.pi/agent \
    && HOME=/tmp/officecli-skel officecli skills pi \
    && for skill in word pptx excel; do HOME=/tmp/officecli-skel officecli skills install "${skill}" pi; done \
    && cp -r /tmp/officecli-skel/.pi/agent/skills /etc/inferlab/pi/agent/skills \
    && rm -rf /tmp/officecli-skel \
    && chmod -R a+rX /etc/inferlab

# Open WebUI連携skillはharness非依存のAgent Skillsとして管理し、Piの管理skillへ追加する。
COPY skills/ /etc/inferlab/pi/agent/skills/
RUN chmod -R a+rX /etc/inferlab \
    && ln -s /etc/inferlab/pi/agent/skills/open-webui/scripts/owui-api /usr/local/bin/owui-api

COPY --chmod=0755 open-terminal/pi/inferlab-pi.sh /usr/local/bin/inferlab-pi
# PowerPointのはみ出し検査。agentが画像を見落としても、描画されない行を機械的に報告する。
COPY --chmod=0755 open-terminal/pi/pptx_check.py /usr/local/bin/pptx-check

# owui-brokerはuserのOpen WebUI API keyとLiteLLM master keyを保持し、user processへ中継する。
# 専用system userで動かし、key directory (mode 700) をuserから読めないようにする。
# owui-api.confはowui-apiにbroker経由の呼び出しを指示する。
COPY --chmod=0644 open-terminal/broker/owui_broker.py /usr/local/lib/inferlab/owui_broker.py
COPY --chmod=0755 open-terminal/broker/inferlab-entrypoint.sh /usr/local/bin/inferlab-entrypoint
# COPY --chmodはcopy先に作るdirectoryにも同じmodeを付けるため、実行権を戻す。
RUN chmod 0755 /usr/local/lib/inferlab \
    && useradd --system --no-create-home --shell /usr/sbin/nologin owui-broker \
    && install -d -o owui-broker -g owui-broker -m 0700 /var/lib/owui-broker /var/lib/owui-broker/keys \
    && printf 'OWUI_BROKER_URL=http://127.0.0.1:8765\n' >/etc/inferlab/owui-api.conf \
    && chmod 0644 /etc/inferlab/owui-api.conf

USER user
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/inferlab-entrypoint"]
CMD ["run"]
