local aws = import 'aws-sdk';

local mandatory_tags = {};

{
	bucket(name, region, options = {}): 

		local computed_options = {
			acceleration_status: false,
			acl:: false,
			allow_insecure_access:: false,
			cors_rule: [],
			lifecycle_rule: [],
			logging: "",
			object_lock_configuration: [],
			object_ownership:: "BucketOwnerEnforced",
			policy_statements: [],
			public_access_block:: true,
			replication_configuration: [],
			request_payer: "BucketOwner",
			server_side_encryption:: true,
			versioning: "Disabled",
			website: {},

			object_lock_enabled: false,
			force_destroy: false,
			tags: {}

		} + options + {
			bucket:: null,
			bucket_prefix: "%s-" % name,

			tags: super.tags + mandatory_tags,

			acceleration_status:: super.acceleration_status,
			cors_rule:: super.cors_rule,
			lifecycle_rule:: super.lifecycle_rule,
			logging:: super.logging,
			object_lock_configuration:: super.object_lock_configuration,
			policy_statements:: super.policy_statements,
			replication_configuration:: super.replication_configuration,
			request_payer:: super.request_payer,
			versioning:: super.versioning,
			website:: super.website
		};

		local all = {
			provider: "aws.%s" % region,
			bucket: "${aws_s3_bucket.%s.id}" % name,
		};


	{
		resource: {
			aws_s3_bucket: {
				[name]: computed_options + {
					provider: "aws.%s" % region,
				}
			},
			aws_s3_bucket_policy: {
				[name]: all + {
					policy: std.manifestJsonEx({
						Version: "2012-10-17",
						Statement: std.flattenArrays([computed_options.policy_statements, if computed_options.allow_insecure_access then [] else [{
							Effect: "Deny",
							Principal: "*",
							Action: "s3:*",
							Resource: [
								"${aws_s3_bucket.%s.arn}/*" % name,
								"${aws_s3_bucket.%s.arn}" % name
							],
							Condition: {
								Bool: {
									"aws:SecureTransport": false
								},
								NumericLessThan: {
									"s3:TlsVersion": 1.2
								}
							}
						}]])
					}, '')
				}
			},
			aws_s3_bucket_ownership_controls: {
				[name]: all + {
					rule: [{
						object_ownership: computed_options.object_ownership
					}]
				}
			},
			[if computed_options.acl != false && computed_options.object_ownership != "BucketOwnerEnforced" then 'aws_s3_bucket_acl' else null]: {
				[name]: all + {
					acl: computed_options.acl,
					depends_on: [
						"aws_s3_bucket_ownership_controls.%s" % name,
						"aws_s3_bucket_public_access_block.%s" % name
					]
				}
			},
			aws_s3_bucket_public_access_block: {
				[name]: all + {
					block_public_acls: computed_options.public_access_block,
					block_public_policy: computed_options.public_access_block,
					ignore_public_acls: computed_options.public_access_block,
					restrict_public_buckets: computed_options.public_access_block
				}
			},
			[if std.member(["Enabled", "Suspended"], computed_options.acceleration_status) then "aws_s3_bucket_accelerate_configuration" else null]: {
				[name]: all + {
					status: computed_options.acceleration_status
				}
			},
			[if computed_options.cors_rule != [] then "aws_s3_bucket_cors_configuration" else null]: {
				[name]: all + {
					cors_rule: computed_options.cors_rule
				}
			},
			[if computed_options.lifecycle_rule != [] then "aws_s3_bucket_lifecycle_configuration" else null]: {
				[name]: all + {
					rule: computed_options.lifecycle_rule
				}
			},
			[if computed_options.logging != "" then "aws_s3_bucket_logging" else null]: {
				[name]: all + {
					target_bucket: computed_options.logging,
					target_prefix: "%s/%s-" % [aws.getCallerIdentity().Account, name]
				}
			},
			[if computed_options.object_lock_configuration != [] then "aws_s3_bucket_object_lock_configuration" else null]: {
				[name]: all + {
					rule: computed_options.object_lock_configuration
				}
			},
			aws_s3_bucket_request_payment_configuration: {
				[name]: all + {
					payer: computed_options.request_payer
				}
			},
			[if computed_options.server_side_encryption then "aws_s3_bucket_server_side_encryption_configuration" else null]: {
				[name]: all + {
					rule: [{
						apply_server_side_encryption_by_default: {
							kms_master_key_id: "${aws_kms_key.s3_%s.id}" % name,
							sse_algorithm: "aws:kms"
						}
					}]
				}
			},
			aws_s3_bucket_versioning: {
				[name]: all + {
					versioning_configuration: {
						status: computed_options.versioning
					}
				}
			},
			[if computed_options.website != {} then "aws_s3_bucket_website_configuration" else null]: {
				[name]: computed_options.website + all
			},
			aws_kms_key: {
				["s3_%s" % name]: {
					provider: "aws.%s" % region,
					
					description: "S3 CMK for %s" % [name],
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
						}]
					}, '  ')
				}
			}
		}
	}
}