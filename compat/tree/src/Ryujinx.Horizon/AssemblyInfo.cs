using System.Runtime.CompilerServices;

// S2Arm: services/S2A.Services serves Horizon services in-thread (see S2AHorizonHooks)
[assembly: InternalsVisibleTo("S2A.Services")]
[assembly: InternalsVisibleTo("S2A.Services.Tests")]
