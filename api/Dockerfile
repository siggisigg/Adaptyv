FROM python:3.12-slim

WORKDIR /app

# Install dependencies first, in their own layer, so editing code doesn't reinstall them.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# --reload restarts the server when files change (the code is mounted from the host in compose).
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
