"""Air-gap検証用FastAPI application。"""

from fastapi import FastAPI

app = FastAPI(title="Air-gap FastAPI")


@app.get("/health")
def health() -> dict[str, str]:
    """applicationの稼働状態を返す。

    Returns:
        稼働状態を示すmapping。
    """
    return {"status": "ok"}
