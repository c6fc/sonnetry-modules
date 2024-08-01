local log2(x) = std.log(x) / std.log(2);

{
	local vpc = self,
	base_vpc(basename, region, cidr, azs, segmentoffset, baseendpoints):: {

		// Overload the name for scalability.
		local name = "%s-%s" % [basename, region],
		local provider = "aws.%s" % [region],
		local vpc_id = "${aws_vpc.%s.id}" % [name],

		local segments = log2(std.length(azs) + segmentoffset),

		local gatewayEndpoints = ["s3", "dynamodb"],

		// Interpolate a single '%s' as region.
		local endpointName(endpoint) = [std.strReplace(endpoint, ".", "-"), 'com.amazonaws.%s.%s' % [region, endpoint]],


		// Interpolate all services now.
		local endpoints = std.map(endpointName, baseendpoints),

		resource: {
			aws_vpc: {
				[name]: {
					provider: provider,
					cidr_block: cidr,
					enable_dns_support: true,
					enable_dns_hostnames: true,

					tags: {
						Name: name
					}
				}
			},
			aws_subnet: {
				["%s-subnet-%s" % [name, azs[i]]]: {
					cidr_block: "${cidrsubnet(aws_vpc.%s.cidr_block, %d, %d)}" % [name, segments, i],
					availability_zone: azs[i],
					provider: provider,
					vpc_id: vpc_id,

					tags: {
						Name: "%s-subnet-%s" % [name, azs[i]]
					}
				}
				for i in std.range(0, std.length(azs) - 1)
			},
			aws_route_table: {
				[name]: {
					provider: provider,
					vpc_id: vpc_id,

					tags: {
						Name: name
					}
				}
			},
			aws_main_route_table_association: {
				[name]: {
					provider: provider,
					vpc_id: vpc_id,
					route_table_id: "${aws_route_table.%s.id}" % [name]
				}
			},
			aws_route_table_association: {

				["%s-%s" % [name, azName]]: {
					local subnetName = "%s-subnet-%s" % [name, azName],

					provider: provider,
					route_table_id: "${aws_route_table.%s.id}" % [name],
					subnet_id: "${aws_subnet.%s.id}" % [subnetName]
				}
				for azName in azs
			},
			
			aws_security_group: {
				["%s-default" % name]: {
					provider: provider,
					name: "%s-default" % name,
					vpc_id: vpc_id
				}
			},
			aws_security_group_rule: {
				["%s-default-ingress" % name]: vpc.sg_single(region, "any:self", "%s-default" % name, "ingress"),
				["%s-default-egress" % name]: vpc.sg_single(region, "all", "%s-default" % name, "egress"),
			}
		} + std.prune({
			aws_vpc_endpoint: {
				["%s-%s" % [name, endpoint[0]]]: {
					provider: provider,
					service_name: endpoint[1],
					vpc_id: vpc_id,

					[if std.member(gatewayEndpoints, endpoint[0]) then null else 'vpc_endpoint_type']: "Interface",
					[if std.member(gatewayEndpoints, endpoint[0]) then null else 'private_dns_enabled']: true,
					[if std.member(gatewayEndpoints, endpoint[0]) then null else 'security_group_ids']: [
						"${aws_security_group.%s-default.id}" % name
					],

					tags: {
						Name: "%s-%s" % [name, endpoint[1]]
					}
				}
				for endpoint in endpoints
			},
			aws_vpc_endpoint_subnet_association: {
				[if std.member(gatewayEndpoints, endpoint[0]) then null else "%s-%s-%s" % [name, endpoint[0], i]]: {
					local vpceName = "%s-%s" % [name, endpoint[0]],
					local subnetName = "%s-subnet-%s" % [name, azs[i]],

					provider: provider,
					subnet_id: "${aws_subnet.%s.id}" % [subnetName],
					vpc_endpoint_id: "${aws_vpc_endpoint.%s.id}" % [vpceName]
				}
				for endpoint in endpoints
				for i in std.range(0, std.length(azs) - 1)
			},
			aws_vpc_endpoint_route_table_association: {
				[if std.member(gatewayEndpoints, endpoint[0]) then "%s-%s" % [name, endpoint[0]] else null]: {
					local vpceName = "%s-%s" % [name, endpoint[0]],

					provider: provider,
					route_table_id: "${aws_route_table.%s.id}" % [name],
					vpc_endpoint_id: "${aws_vpc_endpoint.%s.id}" % [vpceName]
				}
				for endpoint in endpoints
			},
		})
	},
	sg_from(mapping):: [mapping[rule] + {
		description: rule
	} for rule in std.objectFields(mapping)],
	sg_inline(mapping):: [vpc.sg_rule(mapping[rule]) + {
		description: rule
	} for rule in std.objectFields(mapping)],
	sg_shorthand(shorthand):: if shorthand == "all" then (self.sg_rule({
		protocol: "-1",
		cidr_blocks: ["0.0.0.0/0"],
		from_port: 0,
		to_port: 0
	})) else

		local params = std.split(shorthand, ":");

		assert std.length(params) >= 2;

		self.sg_rule({
			cidr_blocks: [],
			protocol: params[0],
			from_port: 0,
			to_port: 65535
		}) + (if params[1] == "self" then {
			'self': true
		} else {
			cidr_blocks: if params[1] == '' then [] else [params[1]],
		}) + (if std.length(params) >= 3 then {
			from_port: std.parseInt(params[2]),
			to_port: std.parseInt(params[2]),
		} else {}) + (if std.length(params) == 4 then {
			to_port: std.parseInt(params[3]),
		} else {}) + (if std.member(['any', 'all', ''], params[0]) then {
			protocol: "-1",
			to_port: 0
		} else {}),
	sg_single(region, shorthand, sg = null, type = null, source = '')::
		local rule = self.sg_shorthand(shorthand);

		std.prune(rule + {
			provider: "aws.%s" % region,

			// [if !rule['self'] && std.length(rule.cidr_blocks) == 0 then 'cidr_blocks' else null]: null,
			[if rule['self'] then null else 'self']: null,
			[if source == '' then null else 'source_security_group_id']: "${aws_security_group.%s.id}" % source,
			[if std.type(sg) == "null" then null else 'security_group_id']: "${aws_security_group.%s.id}" % sg,
			type: type
		}),
	sg_rule(options):: {
		'self': false,
		prefix_list_ids: [],
		security_groups: [],
		ipv6_cidr_blocks: []
	} + options,
	public_vpc(basename, region, cidr, azs, segmentoffset, baseendpoints):: $.base_vpc(basename, region, cidr, azs, segmentoffset, baseendpoints) + {
		// Overload the name for scalability.
		local name = "%s-%s" % [basename, region],
		local provider = "aws.%s" % [region],
		local vpc_id = "${aws_vpc.%s.id}" % [name],

		// Interpolate a single '%s' as region.
		local endpointName(endpoint) =
			if (std.length(std.findSubstr('%s')) == 1) then
				endpoint % [region]
			else
				endpoint,

		// Interpolate all services now.
		local endpoints = std.map(endpointName, baseendpoints),

		resource+: {
			aws_route+: {
				["%s-igw" % [name]]: {
					provider: provider,
					route_table_id: "${aws_route_table.%s.id}" % [name],
					destination_cidr_block: "0.0.0.0/0",
					gateway_id: "${aws_internet_gateway.%s.id}" % [name]
				}
			},
			aws_internet_gateway+: {
				[name]: {
					provider: provider,
					vpc_id: vpc_id,

					tags: {
						Name: name
					}
				}
			}
		}
	},
	private_vpc(basename, region, cidr, azs, segmentoffset, baseendpoints):: $.public_vpc(basename, region, cidr, azs, segmentoffset + std.length(azs), baseendpoints) + {
		// Overload the name for scalability.
		local name = "%s-%s" % [basename, region],
		local provider = "aws.%s" % [region],
		local vpc_id = "${aws_vpc.%s.id}" % [name],

		local segments = log2(std.length(azs) + std.length(azs) + segmentoffset),

		// Interpolate a single '%s' as region.
		local endpointName(endpoint) =
			if (std.length(std.findSubstr('%s')) == 1) then
				endpoint % [region]
			else
				endpoint,

		// Interpolate all services now.
		local endpoints = std.map(endpointName, baseendpoints),

		resource+: {
			aws_route+: {
				["%s-ngw" % [name]]: {
					provider: provider,
					route_table_id: "${aws_route_table.private-%s.id}" % [name],
					destination_cidr_block: "0.0.0.0/0",
					gateway_id: "${aws_nat_gateway.%s.id}" % [name]
				}
			},
			aws_nat_gateway+: {
				[name]: {
					provider: provider,
					allocation_id: "${aws_eip.ngw-%s.id}" % name,
					subnet_id: "${aws_subnet.%s-subnet-%s.id}" % [name, azs[0]],

					tags: {
						Name: name
					}
				}
			},
			aws_subnet+: {
				["%s-private-subnet-%s" % [name, azs[i]]]: {
					cidr_block: "${cidrsubnet(aws_vpc.%s.cidr_block, %d, %d)}" % [name, segments, std.length(azs)+i],
					availability_zone: azs[i],
					provider: provider,
					vpc_id: vpc_id,

					tags: {
						Name: "%s-private-subnet-%s" % [name, azs[i]]
					}
				}
				for i in std.range(0, std.length(azs) - 1)
			},
			aws_route_table+: {
				["private-%s" % name]: {
					provider: provider,
					vpc_id: vpc_id,

					tags: {
						Name: "private-%s" % name
					}
				}
			},
			aws_route_table_association+: {

				["private-%s-%s" % [name, azName]]: {
					local subnetName = "%s-private-subnet-%s" % [name, azName],

					provider: provider,
					route_table_id: "${aws_route_table.private-%s.id}" % [name],
					subnet_id: "${aws_subnet.%s.id}" % [subnetName]
				}
				for azName in azs
			},
			aws_eip: {
				["ngw-%s" % name]: {
					provider: provider,
					vpc: true
				}
			}
		}
	}
}