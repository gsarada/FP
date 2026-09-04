"""
Tools for the FP Researcher agent
"""
import os
from typing import Dict, Any
from datetime import datetime, UTC
import httpx
from agents import function_tool
from tenacity import retry, stop_after_attempt, wait_exponential

# Configuration from environment
INGEST_API_ENDPOINT = os.getenv("INGEST_API_ENDPOINT")
INGEST_API_KEY = os.getenv("INGEST_API_KEY")


def _ingest(document: Dict[str, Any]) -> Dict[str, Any]:
    """Internal function to make the actual API call."""
    key = get_key_value()
    with httpx.Client() as client:
        response = client.post(
            f"{INGEST_API_ENDPOINT}/ingest",
            json=document,
            headers={"x-api-key": key, "Content-Type": "application/json"},
            timeout=30.0
        )
        response.raise_for_status()
        return response.json()

def get_key_value():
    
    try:
        import boto3

        client = boto3.client('apigateway')
        # 2. Call get_api_key with includeValue=True
        response = client.get_api_key(
            apiKey=INGEST_API_KEY,
            includeValue=True # Essential to return the secret plaintext value
        )
        
        # 3. Extract the actual token
        api_key_value = response.get('value')
        
        print(f"Successfully retrieved key value: {api_key_value}")
        
        return api_key_value
    except Exception as e:
        print(f"Error: {e}")
        raise e

@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=10)
)
def ingest_with_retries(document: Dict[str, Any]) -> Dict[str, Any]:
    """Ingest with retry logic for SageMaker cold starts."""
    return _ingest(document)


@function_tool
def ingest_financial_document(topic: str, analysis: str, source: str) -> Dict[str, Any]:
    """
    Ingest a financial document into the Alex knowledge base.
    
    Args:
        topic: The topic or subject of the analysis (e.g., "AAPL Stock Analysis", "Retirement Planning Guide")
        analysis: Detailed analysis or advice with specific data and insights
    
    Returns:
        Dictionary with success status and document ID
    """
    if not INGEST_API_ENDPOINT or not INGEST_API_KEY:
        return {
            "success": False,
            "error": "Ingest API not configured. Running in local mode."
        }
    
    document = {
        "text": analysis,
        "metadata": {
            "topic": topic,
            "source": source,
            "timestamp": datetime.now(UTC).isoformat()
        }
    }
    
    try:
        result = ingest_with_retries(document)
        return {
            "success": True,
            "document_id": result.get("document_id"),  # Changed from documentId
            "message": f"Successfully ingested analysis for {topic}"
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }