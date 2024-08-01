local aws = import 'aws-sdk';

local iam = import 'iam.libsonnet';
local vpc = import 'vpc.libsonnet';

local mandatory_tags = {
	mandatory: true
};

local account = aws.getCallerIdentity().Account;

local rand(seed, mod) = std.parseHex(std.substr(std.md5(seed), 0, 2)) % mod;
local availabilityzones = aws.getAvailabilityZones();

local os = {
	linux: {
		root_path: "/dev/sda1",
		device_command: std.join("\n", [
			"export MP=%s",
			"export VID=%s",
			"export VDEV=/dev/$(lsblk --output NAME,SERIAL | grep $VID | cut -d' ' -f1)",
			"mkfs -t xfs $VDEV",
			"mkdir /$MP",
			"echo UUID=$(blkid -s UUID -o value $VDEV) /$MP xfs defaults,nofail 0 2 | tee -a /etc/fstab",
			"mount -a"
		]),
		device: "/dev/sd%s",
		device_startchar: 102, // "f"
		userdata: std.join("\n", [
			"#! /bin/bash",
			""
		])
	}
};

{
	instance(name, region, options = {}, overrideProd = false):

		local computed_options = {
			os:: "linux",
			
			ami_name:: "amzn2-ami-kernel-5.10-hvm-2.0.20*",
			monitoring: false,
			associate_public_ip_address: true,
			backup_frequency:: null,
			disable_api_termination: false,
			ebs_block_device:: {
				root: 30,
			},
			ebs_optimized: false,
			egress:: {},
			enclave_options: {
				enabled: false
			},
			ephemeral_block_device: [],
			hibernation: false,
			ingress:: {},
			policy_attachments:: [],
			policy_statements:: [],
			instance_type: "t3.micro",
			root_block_device: {
				volume_size: 30,
				volume_type: "gp2"
			},
			subnet_resource:: "",
			schedule:: null,
			tags: {},
			user_data: "",
			vpc_security_group_ids: [],

		} + options + {
			ami: "${data.aws_ami.%s.image_id}" % name,
			availability_zone: "${%s.availability_zone}" % super.subnet_resource,
			egress: super.egress + {},
			ingress: super.ingress + {},
			metadata_options: {
				http_endpoint: "enabled",
				http_tokens: "required"
			},
			root_block_device: (if std.objectHas(super.ebs_block_device, "root") then 
				local dev = super.ebs_block_device.root;
			{
				volume_size: if std.type(dev) == "object" then dev.size else dev,
				volume_type: if std.type(dev) == "object" then "io1" else "gp2",
				[if std.type(dev) == "object" then "iops" else null]: if std.objectHas(dev, "iops") then dev.iops else 1000,
			} else super.root_block_device) + {
				encrypted: true,
				kms_key_id: "${aws_kms_key.ec2_%s.arn}" % name,
			},
			subnet_id: "${%s.id}" % super.subnet_resource,
			tags: super.tags + mandatory_tags + { Name: name },
			vpc_security_group_ids: super.vpc_security_group_ids + ["${aws_security_group.%s.id}" % name]
		};

		local map = os[computed_options.os];
		local non_root_bds = std.filter(function(x) x != "root", std.objectFields(computed_options.ebs_block_device));

	{
		data: {
			aws_ami: {
				[name]: {
					provider: "aws.%s" % region,
					most_recent: true,
					owners: ["137112412989"],

					filter: [{
						name: "name",
						values: [computed_options.ami_name]
					}, {
						name: "is-public",
						values: [true]
					}, {
						name: "state",
						values: ["available"]
					}]
				}
			},
			template_file: {
				["%s_userdata" % name]: {
					template: map.userdata + std.join("\n", [
						map.device_command % [id, "${split(\"-\", aws_ebs_volume.%s-%s.id)[1]}" % [name, id]]
						for id in non_root_bds
					]) + computed_options.user_data
				}
			}
		},
		resource: std.prune({
			aws_instance: {
				[name]: computed_options + {
					provider: "aws.%s" % region,
					iam_instance_profile: "${aws_iam_role.ec2-%s-instance-profile.name}" % name,
					user_data: "${data.template_file.%s_userdata.rendered}" % name,
					
					depends_on: [
						"aws_ebs_volume.%s-%s" % [name, id]
						for id in non_root_bds
					]
				}
			},
			aws_ebs_volume: {
				["%s-%s" % [name, id]]: 

					local dev = computed_options.ebs_block_device[id];

				{
					provider: "aws.%s" % region,
					availability_zone: computed_options.availability_zone,
					encrypted: true,
					kms_key_id: "${aws_kms_key.ec2_%s.arn}" % name,
					size: if std.type(dev) == "object" then dev.size else dev,
					type: if std.type(dev) == "object" then "io1" else "gp2",

					[if std.type(dev) == "object" then "iops" else null]: if std.objectHas(dev, "iops") then dev.iops else 1000,

					tags: computed_options.tags + { Name: "%s-%s" % [name, id] }
				} for id in non_root_bds
			},
			aws_volume_attachment: {
				["%s-%s" % [name, non_root_bds[i]]]: {
					provider: "aws.%s" % region,
					instance_id: "${aws_instance.%s.id}" % name,
					volume_id: "${aws_ebs_volume.%s-%s.id}" % [name, non_root_bds[i]],
					device_name: map.device % std.char(map.device_startchar + i)
				} for i in std.range(0, std.length(non_root_bds) - 1)
			},
			aws_security_group: {
				[name]: {
					provider: "aws.%s" % region,
					name_prefix: "%s-sg-" % name,
					description: "%s-sg ec2 security group" % name,
					vpc_id: "${%s.vpc_id}" % computed_options.subnet_resource,
				}
			},
			aws_security_group_rule: {
				["%s_self_ingress" % name]: vpc.sg_single(region, "any:self", name, 'ingress'),
				["%s_default_egress" % name]: vpc.sg_single(region, "tcp:0.0.0.0/0:443", name, 'egress'),
				["%s_self_egress" % name]: vpc.sg_single(region, "any:self", name, 'egress'),
			} + {
				["%s_%s_egress" % [name, key]]: if std.type(computed_options.egress[key]) == "string" then
						vpc.sg_single(region, computed_options.egress[key], name, 'egress')
					else
						computed_options.egress[key]
				for key in std.objectFields(computed_options.egress)
			} + {
				["%s_%s_ingress" % [name, key]]: if std.type(computed_options.ingress[key]) == "string" then
						vpc.sg_single(region, computed_options.ingress[key], name, 'ingress')
					else
						computed_options.ingress[key]
				for key in std.objectFields(computed_options.ingress)
			},
			aws_kms_key: {
				["ec2_%s" % name]: {
					provider: "aws.%s" % region,
					
					description: "EC2 CMK for %s" % [name],
					customer_master_key_spec: "SYMMETRIC_DEFAULT",
					deletion_window_in_days: 7,
					enable_key_rotation: true,

					policy: std.manifestJsonEx({
						Id: "ExamplePolicy",
						Version: "2012-10-17",
						Statement: [{
							Sid: "Enable IAM policies",
							Effect: "Allow",
							Principal: {
								AWS: "arn:aws:iam::%s:root" % aws.getCallerIdentity().Account
							},
						Action: "kms:*",
						Resource: "*"
					}, {
						Effect: "Allow",
						Principal: {
							Service: "ec2.amazonaws.com",
						},
						Action: [
							"kms:ReEncrypt*",
							"kms:GenerateDataKey*",
							"kms:Encrypt*",
							"kms:Describe*",
							"kms:Decrypt*"
						],
						Resource: "*",
						Condition: {
							StringEquals: {
								"kms:CallerAccount": aws.getCallerIdentity().Account
							}
						}
					}]}, '  ')
				}
			}
		}) + iam.iam_role("ec2-%s-instance-profile" % name,
			"Instance profile for instance %s" % name,
			std.mergePatch(
				computed_options.policy_attachments,
				{
					"AmazonSSMManagedInstanceCore": "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
				}
			),
			{ [if std.length(computed_options.policy_statements) > 0 then 'Statements' else null]: computed_options.policy_statements },
			[{
				Effect: "Allow",
				Principal: {
					Service: "ec2.amazonaws.com"
				},
				Action: "sts:AssumeRole"
			}],
			true
		)
	}
}