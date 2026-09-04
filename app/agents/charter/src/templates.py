"""
Prompt templates for the Chart Maker Agent.
"""

import json
from pydantic import BaseModel
from typing import List


class ChartData(BaseModel):
    name: str
    value: float
    color: str


class Chart(BaseModel):
    key: str
    title: str
    type: str
    description: str
    data: List[ChartData]


class ChartsResponse(BaseModel):
    charts: List[Chart]

CHARTER_INSTRUCTIONS = """You are a Chart Maker Agent that creates visualization data for investment portfolios.

Your task is to analyze the portfolio and output a JSON object containing 4-6 charts that tell a compelling story about the portfolio.

IMPORTANT RULES:
1. Each chart must have: key, title, type, description, and data array
2. Chart types: 'pie', 'bar', 'donut', or 'horizontalBar'
3. Values must be dollar amounts (not percentages - Recharts calculates those)
4. Colors must be hex format like '#3B82F6'
5. Create 4-6 different charts from different perspectives

CHART IDEAS TO IMPLEMENT:
- Asset class distribution (equity vs bonds vs alternatives)
- Geographic exposure (North America, Europe, Asia, etc.)
- Sector breakdown (Technology, Healthcare, Financials, etc.)
- Account type allocation (401k, IRA, Taxable, etc.)
- Top holdings concentration (largest 5-10 positions)
- Tax efficiency (tax-advantaged vs taxable accounts)
"""


def create_charter_task(portfolio_analysis: str) -> str:
    """Generate the task prompt for the Charter agent."""
    # Don't include the full raw portfolio data - just the analysis
    # This reduces context size significantly
    
    return f"""Analyze this investment portfolio and create 4-6 visualization charts.

{portfolio_analysis}

Create charts based on this portfolio data. Calculate aggregated values from the positions shown above.

OUTPUT ONLY THE JSON OBJECT with 4-6 charts - no other text."""

