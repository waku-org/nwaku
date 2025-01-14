---
title: Performance Benchmarks and Test Reports
---


## Introduction
This page summarizes key performance metrics for nwaku and provides links to detailed test reports.

> ## Quick reference
>
> - **10%** decrease in bandwidth usage in larger networks (1000 vs 2000 relay nodes)
> - **0.4s** average, **5.5s** max message propogation latency (2000 relay nodes)
> - Relevancy to Status App: TODO



## Insights
*Some metrics for specific protocols are currently unavailable due to reporting and logging limitations. Improvements are in progress.*

### Bandwidth Usage: nwaku v0.34
Average `libp2p` bandwidth usage for  1KB message size in a 1000 relay nodes network

| Message Rate | libp2p-in (KB/s) | libp2p-out (KB/s) |
|--------------|------------------|-------------------|
| 1 msg/s      | ~10.1            | ~10.3             |
| 1 msg/10s    | ~1.8             | ~1.9              |

### Message Latency: nwaku v0.34.0-rc1
Latency results for 1KB messages (1msg/s, 600 total). Click on config to see detailed report:


| Config            | Avg Latency | Max Latency |
|------------------------|-------------|-------------|
| [Relay](https://www.notion.so/Waku-regression-testing-v0-34-1618f96fb65c803bb7bad6ecd6bafff9) (1000 nodes)     | 0.05s       | 1.6s        |
| [Mixed](https://www.notion.so/Mixed-environment-analysis-1688f96fb65c809eb235c59b97d6e15b) (210 nodes)      | 0.0125s     | 0.007s      |
| [Non-persistent Relay](https://www.notion.so/High-Churn-Relay-Store-Reliability-16c8f96fb65c8008bacaf5e86881160c)   | 0.0125s     | 0.25s       |  


## Testing
### DST
The VAC DST team performs regression testing on all new **nwaku** releases, comparing performance with previous versions. They simulate large Waku networks with a variety of network and protocol configurations that are representative of real-world usage.

**Test Reports**: [DST Reports](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f)  


### QA
The VAC QA team performs interoperability tests for **Nim Waku** and **Go Waku** using the latest main branch images. These tests run daily and verify protocol functionality by targeting specific features of each protocol.  

**Test Reports**: [QA Reports](https://discord.com/channels/1110799176264056863/1196933819614363678)  

### nwaku
The **nwaku** team follows a structured release procedure for all release candidates. This involves deploying RCs to `status.staging` fleet for validation and performing sanity checks.  

**Release Process**: [nwaku Release Procedure](https://github.com/waku-org/nwaku/blob/master/.github/ISSUE_TEMPLATE/prepare_release.md)  


### Research
The Waku Research team conducts a variety of benchmarking, performance testing, proof-of-concept validations and debugging efforts. They also maintaining a Waku simulator designed for small-scale, single-purpose, on-demand testing.


**Test Reports**: [Waku Research Reports](https://www.notion.so/Miscellaneous-2c02516248db4a28ba8cb2797a40d1bb)

**Waku Simulator**: [Waku SImulator Book](https://waku-org.github.io/waku-simulator/)
