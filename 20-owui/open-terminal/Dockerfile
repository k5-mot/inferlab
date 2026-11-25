# Open TerminalへOfficeCLI、Office用skill、共通のAGENTS.md、Pi coding agentを追加する派生image。
# build contextは20-owui。上流imageには手を加えず、/usr/local、/etc/inferlab、/etc/skelへ追加するだけにする。
# multi-user modeではOpen WebUI userごとのOS userで動くため、/home/user (mode 700) ではなく
# 全userが実行できる/usr/localへ導入する。
FROM ghcr.io/open-webui/open-terminal:0.17.22

ARG PI_VERSION=1.6.0
ARG OFFICECLI_VERSION=1.0.163

USER root

# OfficeCLIのpostinstallはrelease binaryを取得するため、build時だけnetworkを必要とする。
RUN npm install --global --prefix /usr/local \
      "@earendil-works/pi-coding-agent@${PI_VERSION}" \
      "@officecli/officecli@${OFFICECLI_VERSION}" \
    && npm cache clean --force

# Open WebUIの通常modelとPiが共通で読むAGENTS.mdとskill。Open Terminalはuser homeの
# ~/AGENTS.mdと~/.agents/skillsをOpen WebUIへ渡し、Piも同じ場所を読む。OfficeCLIのskillはbuild時に固定する。
COPY open-terminal/agent/AGENTS.md /etc/inferlab/agent/AGENTS.md
RUN mkdir -p /tmp/officecli-skel/.pi/agent \
    && HOME=/tmp/officecli-skel officecli skills pi \
    && for skill in word pptx excel; do HOME=/tmp/officecli-skel officecli skills install "${skill}" pi; done \
    && cp -r /tmp/officecli-skel/.pi/agent/skills /etc/inferlab/agent/skills \
    && rm -rf /tmp/officecli-skel \
    && mkdir -p /etc/skel/.agents \
    && ln -s /etc/inferlab/agent/AGENTS.md /etc/skel/AGENTS.md \
    && ln -s /etc/inferlab/agent/skills /etc/skel/.agents/skills

# Piのmodel定義。LiteLLMはllm-broker経由で呼ぶため、keyを含まない。
COPY open-terminal/pi/models.json /etc/inferlab/pi/agent/models.json
COPY open-terminal/pi/settings.json /etc/inferlab/pi/agent/settings.json
COPY --chmod=0755 open-terminal/pi/inferlab-pi.sh /usr/local/bin/inferlab-pi
# PowerPointのはみ出し検査。agentが画像を見落としても、描画されない行を機械的に報告する。
COPY --chmod=0755 open-terminal/agent/pptx_check.py /usr/local/bin/pptx-check

# llm-brokerはLiteLLM master keyを保持し、Piへchat completionsとmodel一覧だけを中継する。
# 専用system userで動かし、keyをuser processから読めないようにする。
COPY --chmod=0644 open-terminal/broker/llm_broker.py /usr/local/lib/inferlab/llm_broker.py
COPY --chmod=0755 open-terminal/broker/inferlab-entrypoint.sh /usr/local/bin/inferlab-entrypoint
# COPY --chmodはcopy先に作るdirectoryにも同じmodeを付けるため、実行権を戻す。
RUN chmod 0755 /usr/local/lib/inferlab \
    && chmod -R a+rX /etc/inferlab \
    && useradd --system --no-create-home --shell /usr/sbin/nologin llm-broker

USER user
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/inferlab-entrypoint"]
CMD ["run"]
