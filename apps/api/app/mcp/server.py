"""MCP Server implementation."""
from mcp.server import Server
from mcp.types import Tool, TextContent

from app.tools.tfl import get_line_status, get_bike_availability, plan_journey


def create_mcp_server() -> Server:
    """Create and configure the MCP server."""
    server = Server("openvelox-tfl")
    
    @server.list_tools()
    async def list_tools():
        return [
            Tool(
                name="get_line_status",
                description="Get current status for TfL lines (Tube, DLR, Overground, Elizabeth line)",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "line_id": {
                            "type": "string",
                            "description": "Line ID (e.g., 'victoria', 'northern', 'dlr'). Omit for all lines."
                        }
                    }
                }
            ),
            Tool(
                name="get_bike_availability",
                description="Get Santander Cycles bike availability at stations",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "station_id": {
                            "type": "string",
                            "description": "Station ID. Omit for nearby stations."
                        },
                        "lat": {"type": "number"},
                        "lon": {"type": "number"},
                        "radius": {"type": "integer", "default": 500}
                    }
                }
            ),
            Tool(
                name="plan_journey",
                description="Plan a journey between two locations in London",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "from_location": {"type": "string", "description": "Starting point"},
                        "to_location": {"type": "string", "description": "Destination"},
                        "mode": {
                            "type": "string",
                            "enum": ["tube", "bus", "bike", "walking", "any"],
                            "default": "any"
                        }
                    },
                    "required": ["from_location", "to_location"]
                }
            ),
        ]
    
    @server.call_tool()
    async def call_tool(name: str, arguments: dict):
        if name == "get_line_status":
            result = await get_line_status(arguments.get("line_id"))
            return [TextContent(type="text", text=str(result))]
        elif name == "get_bike_availability":
            result = await get_bike_availability(
                arguments.get("station_id"),
                arguments.get("lat"),
                arguments.get("lon"),
                arguments.get("radius", 500)
            )
            return [TextContent(type="text", text=str(result))]
        elif name == "plan_journey":
            result = await plan_journey(
                arguments["from_location"],
                arguments["to_location"],
                arguments.get("mode", "any")
            )
            return [TextContent(type="text", text=str(result))]
        else:
            raise ValueError(f"Unknown tool: {name}")
    
    return server
