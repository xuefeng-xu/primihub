// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT license.

#include "encryptor.h"
#include "modulus.h"
#include "randomtostd.h"
#include "util/common.h"
#include "util/iterator.h"
#include "util/polyarithsmallmod.h"
#include "util/rlwe.h"
#include "util/scalingvariant.h"
#include "kernelutils.cuh"
#include "kernelprovider.cuh"
#include "util/randomgenerator.cuh"
#include <chrono>
#include <algorithm>
#include <stdexcept>

using namespace std;
using namespace sigma::util;

namespace sigma
{
    Encryptor::Encryptor(const SIGMAContext &context, const PublicKey &public_key) : context_(context)
    {
        // Verify parameters
        if (!context_.parameters_set())
        {
            throw invalid_argument("encryption parameters are not set correctly");
        }

        set_public_key(public_key);

        auto &parms = context_.key_context_data()->parms();
        auto &coeff_modulus = parms.coeff_modulus();
        size_t coeff_count = parms.poly_modulus_degree();
        size_t coeff_modulus_size = coeff_modulus.size();

//        temp_noise_.resize(coeff_count * coeff_modulus_size);

        // Quick sanity check
        if (!product_fits_in(coeff_count, coeff_modulus_size, size_t(2)))
        {
            throw logic_error("invalid parameters");
        }
    }

    Encryptor::Encryptor(const SIGMAContext &context, const SecretKey &secret_key) : context_(context)
    {
        // Verify parameters
        if (!context_.parameters_set())
        {
            throw invalid_argument("encryption parameters are not set correctly");
        }

        set_secret_key(secret_key);

        auto &parms = context_.key_context_data()->parms();
        auto &coeff_modulus = parms.coeff_modulus();
        size_t coeff_count = parms.poly_modulus_degree();
        size_t coeff_modulus_size = coeff_modulus.size();

//        temp_noise_.resize(coeff_count * coeff_modulus_size);

        random_generator_ = new RandomGenerator();
        random_generator_->prepare_states(coeff_count);

        // Quick sanity check
        if (!product_fits_in(coeff_count, coeff_modulus_size, size_t(2)))
        {
            throw logic_error("invalid parameters");
        }
    }

    Encryptor::Encryptor(const SIGMAContext &context, const PublicKey &public_key, const SecretKey &secret_key)
        : context_(context)
    {
        // Verify parameters
        if (!context_.parameters_set())
        {
            throw invalid_argument("encryption parameters are not set correctly");
        }

        set_public_key(public_key);
        set_secret_key(secret_key);

        auto &parms = context_.key_context_data()->parms();
        auto &coeff_modulus = parms.coeff_modulus();
        size_t coeff_count = parms.poly_modulus_degree();
        size_t coeff_modulus_size = coeff_modulus.size();

//        temp_noise_.resize(coeff_count * coeff_modulus_size);

        // Quick sanity check
        if (!product_fits_in(coeff_count, coeff_modulus_size, size_t(2)))
        {
            throw logic_error("invalid parameters");
        }
    }

    Encryptor::~Encryptor() {
        delete random_generator_;
    }

    void Encryptor::encrypt_zero_internal(
        parms_id_type parms_id, bool is_asymmetric, bool save_seed, Ciphertext &destination,
        MemoryPoolHandle pool) const//false false
    {
        // Verify parameters.
        if (!pool)
        {
            throw invalid_argument("pool is uninitialized");
        }

        auto context_data_ptr = context_.get_context_data(parms_id);
        if (!context_data_ptr)
        {
            throw invalid_argument("parms_id is not valid for encryption parameters");
        }

        auto &context_data = *context_.get_context_data(parms_id);
        auto &parms = context_data.parms();
        size_t coeff_modulus_size = parms.coeff_modulus().size();
        size_t coeff_count = parms.poly_modulus_degree();
        bool is_ntt_form = false;

        if (parms.scheme() == scheme_type::ckks || parms.scheme() == scheme_type::bgv)
        {
            is_ntt_form = true;
        }
        else if (parms.scheme() != scheme_type::bfv)
        {
            throw invalid_argument("unsupported scheme");
        }

        // Resize destination and save results
        destination.resize(context_, parms_id, 2);

        // If asymmetric key encryption
        if (is_asymmetric)
        {
            auto prev_context_data_ptr = context_data.prev_context_data();
            if (prev_context_data_ptr)
            {
                // Requires modulus switching
                auto &prev_context_data = *prev_context_data_ptr;
                auto &prev_parms_id = prev_context_data.parms_id();
                auto rns_tool = prev_context_data.rns_tool();

                // Zero encryption without modulus switching
                Ciphertext temp(pool);
                util::encrypt_zero_asymmetric(public_key_, context_, prev_parms_id, is_ntt_form, temp);

                // Modulus switching
                SIGMA_ITERATE(iter(temp, destination), temp.size(), [&](auto I) {
                    if (parms.scheme() == scheme_type::ckks)
                    {
                        rns_tool->divide_and_round_q_last_ntt_inplace(
                            get<0>(I), prev_context_data.small_ntt_tables(), pool);
                    }
                    // bfv switch-to-next
                    else if (parms.scheme() == scheme_type::bfv)
                    {
                        rns_tool->divide_and_round_q_last_inplace(get<0>(I), pool);
                    }
                    // bgv switch-to-next
                    else if (parms.scheme() == scheme_type::bgv)
                    {
                        rns_tool->mod_t_and_divide_q_last_ntt_inplace(
                            get<0>(I), prev_context_data.small_ntt_tables(), pool);
                    }
                    set_poly(get<0>(I), coeff_count, coeff_modulus_size, get<1>(I));
                });

                destination.parms_id() = parms_id;
                destination.is_ntt_form() = is_ntt_form;
                destination.scale() = temp.scale();
                destination.correction_factor() = temp.correction_factor();
            }
            else
            {
                // Does not require modulus switching
                util::encrypt_zero_asymmetric(public_key_, context_, parms_id, is_ntt_form, destination);
            }
        }
        else
        {//从这开始
            // Does not require modulus switching
            util::encrypt_zero_symmetric(secret_key_, context_, parms_id, is_ntt_form, save_seed, destination);
        }
    }

    void Encryptor::encrypt_internal(
        const Plaintext &plain, bool is_asymmetric, bool save_seed, Ciphertext &destination,
        MemoryPoolHandle pool) const
    {
        // Minimal verification that the keys are set
        if (is_asymmetric)
        {
            if (!is_metadata_valid_for(public_key_, context_))
            {
                throw logic_error("public key is not set");
            }
        }
        else
        {
            if (!is_metadata_valid_for(secret_key_, context_))
            {
                throw logic_error("secret key is not set");
            }
        }

        // Verify that plain is valid
        if (!is_valid_for(plain, context_))
        {
            throw invalid_argument("plain is not valid for encryption parameters");
        }

        auto scheme = context_.key_context_data()->parms().scheme();
        if (scheme == scheme_type::bfv)
        {
            if (plain.is_ntt_form())
            {
                throw invalid_argument("plain cannot be in NTT form");
            }

            encrypt_zero_internal(context_.first_parms_id(), is_asymmetric, save_seed, destination, pool);

            // Multiply plain by scalar coeff_div_plaintext and reposition if in upper-half.
            // Result gets added into the c_0 term of ciphertext (c_0,c_1).
            multiply_add_plain_with_scaling_variant(plain, *context_.first_context_data(), *iter(destination));
        }
        else if (scheme == scheme_type::ckks)
        {
            if (!plain.is_ntt_form())
            {
                throw invalid_argument("plain must be in NTT form");
            }

            auto context_data_ptr = context_.get_context_data(plain.parms_id());
            if (!context_data_ptr)
            {
                throw invalid_argument("plain is not valid for encryption parameters");
            }
            encrypt_zero_internal(plain.parms_id(), is_asymmetric, save_seed, destination, pool);

            auto &parms = context_.get_context_data(plain.parms_id())->parms();
            auto &coeff_modulus = parms.coeff_modulus();
            size_t coeff_modulus_size = coeff_modulus.size();
            size_t coeff_count = parms.poly_modulus_degree();

            // The plaintext gets added into the c_0 term of ciphertext (c_0,c_1).
            ConstRNSIter plain_iter(plain.data(), coeff_count);
            RNSIter destination_iter = *iter(destination);
            add_poly_coeffmod(destination_iter, plain_iter, coeff_modulus_size, coeff_modulus, destination_iter);

            destination.scale() = plain.scale();
        }
        else if (scheme == scheme_type::bgv)
        {
            if (plain.is_ntt_form())
            {
                throw invalid_argument("plain cannot be in NTT form");
            }
            encrypt_zero_internal(context_.first_parms_id(), is_asymmetric, save_seed, destination, pool);

            auto &context_data = *context_.first_context_data();
            auto &parms = context_data.parms();
            auto &coeff_modulus = parms.coeff_modulus();
            size_t coeff_modulus_size = coeff_modulus.size();
            size_t coeff_count = parms.poly_modulus_degree();
            size_t plain_coeff_count = plain.coeff_count();
            uint64_t plain_upper_half_threshold = context_data.plain_upper_half_threshold();
            auto plain_upper_half_increment = context_data.plain_upper_half_increment();
            auto ntt_tables = iter(context_data.small_ntt_tables());

            // c_{0} = pk_{0}*u + p*e_{0} + M
            Plaintext plain_copy = plain;
            // Resize to fit the entire NTT transformed (ciphertext size) polynomial
            // Note that the new coefficients are automatically set to 0
            plain_copy.resize(coeff_count * coeff_modulus_size);
            RNSIter plain_iter(plain_copy.data(), coeff_count);
            if (!context_data.qualifiers().using_fast_plain_lift)
            {
                // Allocate temporary space for an entire RNS polynomial
                // Slight semantic misuse of RNSIter here, but this works well
                SIGMA_ALLOCATE_ZERO_GET_RNS_ITER(temp, coeff_modulus_size, coeff_count, pool);

                SIGMA_ITERATE(iter(plain_copy.data(), temp), plain_coeff_count, [&](auto I) {
                    auto plain_value = get<0>(I);
                    if (plain_value >= plain_upper_half_threshold)
                    {
                        add_uint(plain_upper_half_increment, coeff_modulus_size, plain_value, get<1>(I));
                    }
                    else
                    {
                        *get<1>(I) = plain_value;
                    }
                });

                context_data.rns_tool()->base_q()->decompose_array(temp, coeff_count, pool);

                // Copy data back to plain
                set_poly(temp, coeff_count, coeff_modulus_size, plain_copy.data());
            }
            else
            {
                // Note that in this case plain_upper_half_increment holds its value in RNS form modulo the
                // coeff_modulus primes.

                // Create a "reversed" helper iterator that iterates in the reverse order both plain RNS components and
                // the plain_upper_half_increment values.
                auto helper_iter = reverse_iter(plain_iter, plain_upper_half_increment);
                advance(helper_iter, -safe_cast<ptrdiff_t>(coeff_modulus_size - 1));

                SIGMA_ITERATE(helper_iter, coeff_modulus_size, [&](auto I) {
                    SIGMA_ITERATE(iter(*plain_iter, get<0>(I)), plain_coeff_count, [&](auto J) {
                        get<1>(J) =
                            SIGMA_COND_SELECT(get<0>(J) >= plain_upper_half_threshold, get<0>(J) + get<1>(I), get<0>(J));
                    });
                });
            }
            // Transform to NTT domain
            ntt_negacyclic_harvey(plain_iter, coeff_modulus_size, ntt_tables);

            // The plaintext gets added into the c_0 term of ciphertext (c_0,c_1).
            RNSIter destination_iter = *iter(destination);
            add_poly_coeffmod(destination_iter, plain_iter, coeff_modulus_size, coeff_modulus, destination_iter);
        }
        else
        {
            throw invalid_argument("unsupported scheme");
        }
    }

    void Encryptor::sample_symmetric_ckks_c1_internal(Ciphertext &destination) const {

        destination.resize(context_, context_.first_parms_id(), 1);
        destination.is_ntt_form() = true;
        destination.scale() = 1.0;
        destination.correction_factor() = 1;

        auto &parms = context_.first_context_data()->parms();

        auto bootstrap_prng = parms.random_generator()->create();

        prng_seed_type public_prng_seed;
        bootstrap_prng->generate(prng_seed_byte_count, reinterpret_cast<sigma_byte *>(public_prng_seed.data()));

        // Set up a new default PRNG for expanding u from the seed sampled above
        auto ciphertext_prng = UniformRandomGeneratorFactory::DefaultFactory()->create(public_prng_seed);

        // Sample the NTT form directly
        sample_poly_uniform(ciphertext_prng, parms, destination.data());

    }

    void Encryptor::encrypt_symmetric_ckks_internal(const Plaintext &plain, Ciphertext &destination, Ciphertext &c1) {
//        auto time_start0 = std::chrono::high_resolution_clock::now();
        if (!is_metadata_valid_for(secret_key_, context_))
        {
            throw logic_error("secret key is not set");
        }

        // Verify that plain is valid
//        if (!is_valid_for(plain, context_))
//        {
//            throw invalid_argument("plain is not valid for encryption parameters");
//        }

        if (!plain.is_ntt_form())
        {
            throw invalid_argument("plain must be in NTT form");
        }

        auto context_data_ptr = context_.get_context_data(plain.parms_id());
        if (!context_data_ptr)
        {
            throw invalid_argument("plain is not valid for encryption parameters");
        }

        auto &context_data = *context_.get_context_data(plain.parms_id());
        auto &params = context_data.parms();
        auto &coeff_modulus = params.coeff_modulus();
        auto &device_coeff_modulus = params.device_coeff_modulus();
        auto ntt_tables = context_data.device_small_ntt_tables();
        size_t coeff_modulus_size = coeff_modulus.size();
        size_t coeff_count = params.poly_modulus_degree();

        destination.resize(context_, plain.parms_id(), 1);
        destination.is_ntt_form() = true;
        destination.scale() = 1.0;
        destination.correction_factor() = 1;
        destination.alloc_device_data();

        uint64_t *c0 = destination.device_data();

//        auto noise = DeviceArray<uint64_t>(coeff_count * coeff_modulus_size);
        destination.temp_noise_.resize(coeff_count * coeff_modulus_size);

        kernel_util::sample_poly_cbd(
                random_generator_, device_coeff_modulus.get(), coeff_modulus_size, coeff_count, destination.temp_noise_.get());

        auto plain_data = plain.device_data();
        auto c1_device_data = c1.device_data();

        for (size_t i = 0; i < coeff_modulus_size; i++) {
            kernel_util::dyadic_product_coeffmod(
                    secret_key_.data().device_data() + i * coeff_count, c1_device_data + i * coeff_count,
                    coeff_count, 1, 1, coeff_modulus[i], c0 + i * coeff_count);

            // Transform the noise e into NTT representation
            kernel_util::g_ntt_negacyclic_harvey(destination.temp_noise_.get() + i * coeff_count, coeff_count, ntt_tables[i]);

            kernel_util::add_negate_add_poly_coeffmod(
                    destination.temp_noise_.get() + i * coeff_count, c0 + i * coeff_count, plain_data + i * coeff_count,
                    coeff_count, coeff_modulus[i].value(), c0 + i * coeff_count);
        }

        destination.scale() = plain.scale();

//        auto time_end0 = std::chrono::high_resolution_clock::now();
//        auto time_diff0 = std::chrono::duration_cast<std::chrono::microseconds >(time_end0 - time_start0);
//        std::cout << "encryptor inner file end [" << time_diff0.count() << " microseconds]" << std::endl;
    }
} // namespace sigma
