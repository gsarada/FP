import json
from ingest_s3vectors import ingest
from search_s3vectors import search

def lambda_handler(event, context):
    # 1. Identify which static endpoint was triggered
    # event['resource path'] will contain either "/ingest" or "/search"
    route = event.get('path') 
    
    # 2. Parse the incoming POST body payload safely
    try:
        body_payload = json.loads(event.get('body', '{}')) if event.get('body') else {}
    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'Invalid JSON body structure'})
        }

    # 3. Route business logic based strictly on the static path string
    if route == "/ingest":
        return ingest(body_payload)
        
    elif route == "/search":
        # Process searching using query parameters from the POST body
        return search(body_payload)

    # Fallback safety handler
    return {
        'statusCode': 404,
        'body': json.dumps({'error': f'Route {route} not recognized'})
    }
