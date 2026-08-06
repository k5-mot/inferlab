# import asyncio
# import logging

# logger = logging.getLogger(__name__)

# SKILLS = [
#     "skills-sh/anthropics/skills/pdf",
#     "official/migration/openclaw-migration",
# ]


# async def handle(event_type: str, context: dict):
#     for skill in SKILLS:
#         logger.info("Installing Hermes skill: %s", skill)

#         proc = await asyncio.create_subprocess_exec(
#             "/opt/hermes/bin/hermes",
#             "skills",
#             "install",
#             skill,
#             stdout=asyncio.subprocess.PIPE,
#             stderr=asyncio.subprocess.STDOUT,
#         )

#         stdout, _ = await proc.communicate()

#         if stdout:
#             logger.info(
#                 "hermes skills install %s:\n%s",
#                 skill,
#                 stdout.decode(errors="replace"),
#             )

#         if proc.returncode != 0:
#             logger.error(
#                 "Failed to install skill %s (exit=%d)",
#                 skill,
#                 proc.returncode,
#             )


import asyncio
import logging
from pathlib import Path

logger = logging.getLogger("hooks.install-skills")

SCRIPT = Path(__file__).with_name("install.sh")


async def handle(event_type: str, context: dict) -> None:
    logger.info("Starting external skill installation")

    proc = await asyncio.create_subprocess_exec(
        "/bin/sh",
        str(SCRIPT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    stdout, _ = await proc.communicate()

    if stdout:
        logger.info(
            "install-skills output:\n%s",
            stdout.decode(errors="replace"),
        )

    if proc.returncode != 0:
        logger.error(
            "install-skills failed: exit=%d",
            proc.returncode,
        )
    else:
        logger.info("External skill installation completed")
