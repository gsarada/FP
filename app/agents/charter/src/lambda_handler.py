"""
Chart Maker Agent Lambda Handler
"""

import os
import json
import asyncio
import logging
from typing import Dict, Any

from agents import Agent, Runner, trace
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
from litellm.exceptions import RateLimitError

try:
    from dotenv import load_dotenv
    load_dotenv(override=True)
except ImportError:
    pass

# Import database package
from src import Database

from templates import CHARTER_INSTRUCTIONS, ChartsResponse
from agent import create_agent
from observability import observe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

@retry(
    retry=retry_if_exception_type(RateLimitError),
    stop=stop_after_attempt(5),
    wait=wait_exponential(multiplier=1, min=4, max=60),
    before_sleep=lambda retry_state: logger.info(f"Charter: Rate limit hit, retrying in {retry_state.next_action.sleep} seconds...")
)
async def run_charter_agent(job_id: str, portfolio_data: Dict[str, Any], db=None) -> Dict[str, Any]:
    """Run the charter agent to generate visualization data."""
    
    # Create agent without tools - will output JSON
    model, task = create_agent(job_id, portfolio_data)
    charts_data = None
    charts_saved = False
    # Run agent - no tools, no context
    with trace("Charter Agent"):
        agent = Agent(
            name="Chart Maker",
            instructions=CHARTER_INSTRUCTIONS,
            model=model,
            output_type=ChartsResponse,
        )
        
        result = await Runner.run(
            agent,
            input=task,
            max_turns=5  # Reduced since we expect one-shot JSON response
        )
        
        # Extract and parse JSON from the output
        output = result.final_output
        
        # Log the actual output for debugging
        if output:
            logger.info(f"Charter: Output preview: {output}")
            charts = output.charts
            logger.info(f"Charter: Successfully found {len(charts)} charts")
            charts_data = {
                chart.key: chart.model_dump(exclude={"key"})
                for chart in charts
            }
            logger.info(f"Charter: Created charts_data with keys: {[chart.key for chart in charts]}")
        else:
            logger.warning("Charter: Agent returned empty output!")
            # Check if there were any messages
            if hasattr(result, 'messages') and result.messages:
                logger.info(f"Charter: Number of messages: {len(result.messages)}")
                for i, msg in enumerate(result.messages):
                    logger.info(f"Charter: Message {i}: {str(msg)[:500]}")
            
        # Save to database
        if db and charts_data:
            try:
                success = db.jobs.update_charts(job_id, charts_data)
                charts_saved = bool(success)
                logger.info(f"Charter: Database update returned: {success}")
            except Exception as e:
                logger.error(f"Charter: Database error: {e}")
                    
        return {
            'success': charts_saved,
            'message': f'Generated {len(charts_data) if charts_data else 0} charts' if charts_saved else 'Failed to generate charts',
            'charts_generated': len(charts_data) if charts_data else 0,
            'chart_keys': list(charts_data.keys()) if charts_data else []
        }

def lambda_handler(event, context):
    """
    Lambda handler expecting job_id and portfolio_data in event.

    Expected event:
    {
        "job_id": "uuid",
        "portfolio_data": {...}
    }
    """
    # Wrap entire handler with observability context
    with observe():
        try:
            logger.info(f"Charter Lambda invoked with event keys: {list(event.keys()) if isinstance(event, dict) else 'not a dict'}")

            # Parse event
            if isinstance(event, str):
                event = json.loads(event)

            job_id = event.get('job_id')
            if not job_id:
                return {
                    'statusCode': 400,
                    'body': json.dumps({'error': 'job_id is required'})
                }

            # Initialize database first
            db = Database()

            portfolio_data = event.get('portfolio_data')
            if not portfolio_data:
                # Load portfolio data from database (like Reporter does)
                logger.info(f"Charter: Loading portfolio data for job {job_id}")
                try:
                    job = db.jobs.find_by_id(job_id)
                    if job:
                        user_id = job['clerk_user_id']
                        user = db.users.find_by_clerk_id(user_id)
                        accounts = db.accounts.find_by_user(user_id)

                        portfolio_data = {
                            'user_id': user_id,
                            'job_id': job_id,
                            'years_until_retirement': user.get('years_until_retirement', 30) if user else 30,
                            'accounts': []
                        }

                        for account in accounts:
                            account_data = {
                                'id': account['id'],
                                'name': account['account_name'],
                                'type': account.get('account_type', 'investment'),
                                'cash_balance': float(account.get('cash_balance', 0)),
                                'positions': []
                            }

                            positions = db.positions.find_by_account(account['id'])
                            for position in positions:
                                instrument = db.instruments.find_by_symbol(position['symbol'])
                                if instrument:
                                    account_data['positions'].append({
                                        'symbol': position['symbol'],
                                        'quantity': float(position['quantity']),
                                        'instrument': instrument
                                    })

                            portfolio_data['accounts'].append(account_data)

                        logger.info(f"Charter: Loaded {len(portfolio_data['accounts'])} accounts with positions")
                    else:
                        logger.error(f"Charter: Job {job_id} not found")
                        return {
                            'statusCode': 404,
                            'body': json.dumps({'error': 'Job not found'})
                        }
                except Exception as e:
                    logger.error(f"Charter: Error loading portfolio data: {e}")
                    return {
                        'statusCode': 500,
                        'body': json.dumps({'error': f'Failed to load portfolio data: {str(e)}'})
                    }

            logger.info(f"Charter: Processing job {job_id}")

            # Run the agent
            result = asyncio.run(run_charter_agent(job_id, portfolio_data, db))

            logger.info(f"Charter completed for job {job_id}: {result}")

            return {
                'statusCode': 200,
                'body': json.dumps(result)
            }

        except Exception as e:
            logger.error(f"Error in charter: {e}", exc_info=True)
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'success': False,
                    'error': str(e)
                })
            }

# For local testing
if __name__ == "__main__":
    test_event = {
        "job_id": "550e8400-e29b-41d4-a716-446655440001",
        "portfolio_data": {
            "accounts": [
                {
                    "id": "acc1",
                    "name": "401(k)",
                    "type": "401k",
                    "cash_balance": 5000,
                    "positions": [
                        {
                            "symbol": "SPY",
                            "quantity": 100,
                            "instrument": {
                                "name": "SPDR S&P 500 ETF",
                                "current_price": 450,
                                "allocation_asset_class": {"equity": 100},
                                "allocation_regions": {"north_america": 100},
                                "allocation_sectors": {"technology": 30, "healthcare": 15, "financials": 15, "consumer_discretionary": 20, "industrials": 20}
                            }
                        }
                    ]
                }
            ]
        }
    }
    
    result = lambda_handler(test_event, None)
    print(json.dumps(result, indent=2))